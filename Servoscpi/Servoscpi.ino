// ServoSCPI.ino
//
// SCPI-over-TCP command server for the 6-servo bank. First networked step
// towards the full closed-loop rig: no PID / encoder feedback yet, just
// direct position commands, plus storage for the next test's parameters.
// Everything currently runs on one core (core0) -- there's no real-time
// control loop yet to protect from network jitter, so there's no need to
// split work across cores for this increment. ControlState (in HastaDrivers)
// already guards everything with a mutex though, so when a PID loop lands
// on its own core later, none of the command handlers below need to change.
//
// Wire protocol -- newline-terminated ASCII, one command per line, sent
// over a plain TCP socket on port 5025 (the conventional raw-socket SCPI
// port a lot of bench instruments use, so generic SCPI tools/scripts will
// find it where they expect it -- `nc <board-ip> 5025` works fine to poke
// at this by hand):
//
//   *IDN?              -> identification string
//   POS<ch> <deg>      -> command channel ch (0-5, e.g. POS2 45) to deg (0-180,
//                         currently mapped onto a 500-2500us pulse range --
//                         see the range note in ServoBank.h)
//   POS<ch>?           -> query last commanded position of channel ch (e.g. POS2?)
//   ENABLE <0|1>       -> enable/disable servo output
//   ENABLE?            -> query enabled state
//   TEST               -> followed by a SECOND line: the test definition
//                         as compact JSON, e.g.
//                         {"type":"chirp","f0":0,"f1":20,"period":20,"amplitude":10,"center":90}
//   TEST?              -> query current test definition as JSON
//
// TEST is deliberately two lines rather than "TEST <json>" on one line:
// Vrekrer_scpi_parser tokenizes a command's parameters on commas, which
// would shred a JSON object into garbage tokens. Sending the JSON as its
// own line sidesteps that -- the handler reads it straight off the socket
// itself, untouched by the SCPI parameter tokenizer. Send both lines in
// one write() from the client so they arrive together; the handler blocks
// briefly (Stream's default read timeout) waiting for that second line.
//
// Keep the JSON compact (no embedded spaces) -- there's no reason to add
// any, and it keeps things simple regardless of exactly how the tokenizer
// treats whitespace elsewhere on the line.

#include <WiFi.h>
#include <pico/cyw43_driver.h>

// Vrekrer_scpi_parser splits its implementation out of the header into a
// few sibling "_code.h" files, gated behind this macro. The library's own
// Vrekrer_scpi_parser.cpp is the ONE place meant to supply the real
// implementation for the whole project (you'll see it compiled separately
// under "Building libraries..."); every consumer -- including this sketch
// -- should define this macro before including the header, so it only
// pulls in declarations rather than a second copy of the same functions.
#define VREKRER_SCPI_PARSER_NO_IMPL
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <ServoBank.h>
#include <ControlState.h>
#include "secrets.h"

// --- CYW43 (RM2 breakout on SP/CE) pin fix -- confirmed working ---
uint CYW43_PINS_SPCE[CYW43_PIN_INDEX_WL_COUNT] = {
    32, // REG_ON
    35, // DATA_OUT
    35, // DATA_IN
    35, // HOST_WAKE
    34, // CLOCK
    33, // CS
};

const uint16_t SCPI_PORT = 5025;
WiFiServer scpiServer(SCPI_PORT);
WiFiClient scpiClient;

SCPI_Parser scpi;

const uint8_t SERVO_PINS[NUM_SERVOS] = { 6, 7, 20, 21, 22, 26 };
ServoBank servos(SERVO_PINS, NUM_SERVOS, 200); // 600Hz carrier -- confirmed working ceiling

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,ServoSCPI,1,0.1"));
}

// POS<ch> / POS<ch>? use Vrekrer_scpi_parser's numeric-suffix feature (the
// "#" in the registered command string) rather than taking the channel as
// a parameter -- commands.Last() returns the matched header text (e.g.
// "POS2" or "POS2?"), and sscanf's "%*[POS]" skips the literal P/O/S
// letters so "%u" picks up just the trailing digit(s). Same pattern as
// the library's own Numeric_suffixes example.
void SetPositionN(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String header = String(commands.Last());
    int channel = -1;
    sscanf(header.c_str(), "%*[POS]%u", &channel);
    if (channel < 0 || channel >= NUM_SERVOS) {
        interface.println(F("ERR channel out of range"));
        return;
    }
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing degrees"));
        return;
    }
    float deg = String(parameters[0]).toFloat();
    ControlState::setServoPos(channel, deg);
    interface.println(F("OK"));
}

void GetPositionN(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String header = String(commands.Last());
    int channel = -1;
    sscanf(header.c_str(), "%*[POS]%u", &channel);
    if (channel < 0 || channel >= NUM_SERVOS) {
        interface.println(F("ERR channel out of range"));
        return;
    }
    interface.println(ControlState::getServoPos(channel), 2);
}

void SetEnabled(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing 0|1"));
        return;
    }
    bool en = String(parameters[0]).toInt() != 0;
    ControlState::setEnabled(en);
    interface.println(F("OK"));
}

void GetEnabled(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(ControlState::getEnabled() ? F("1") : F("0"));
}

// TEST reads its JSON payload as a second raw line straight off the
// socket -- see the wire-protocol note at the top of the file for why.
void SetTest(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    if (err) {
        interface.print(F("ERR bad JSON: "));
        interface.println(err.c_str());
        return;
    }

    TestConfig t = ControlState::getTest(); // start from current, only override given fields
    const char* type = doc["type"] | "chirp";
    t.type = (strcmp(type, "sine") == 0) ? ExcitationType::SINE : ExcitationType::CHIRP;
    t.f0Hz = doc["f0"] | t.f0Hz;
    t.f1Hz = doc["f1"] | t.f1Hz;
    t.periodS = doc["period"] | t.periodS;
    t.amplitudeDeg = doc["amplitude"] | t.amplitudeDeg;
    t.centerDeg = doc["center"] | t.centerDeg;

    ControlState::setTest(t);
    interface.println(F("OK"));
}

void GetTest(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    TestConfig t = ControlState::getTest();
    JsonDocument doc;
    doc["type"] = (t.type == ExcitationType::SINE) ? "sine" : "chirp";
    doc["f0"] = t.f0Hz;
    doc["f1"] = t.f1Hz;
    doc["period"] = t.periodS;
    doc["amplitude"] = t.amplitudeDeg;
    doc["center"] = t.centerDeg;
    serializeJson(doc, interface);
    interface.println();
}

// ---------------- setup / loop ----------------

void connectWiFi() {
    Serial.print(F("[WiFi] Connecting to ")); Serial.println(WIFI_SSID);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    while (WiFi.status() != WL_CONNECTED) {
        delay(500);
        Serial.print(".");
    }
    Serial.println();
    Serial.print(F("[WiFi] Connected, IP=")); Serial.println(WiFi.localIP());
}

void setup() {
    cyw43_set_pins_wl(CYW43_PINS_SPCE); // must be first -- before any WiFi/hw touch

    Serial.begin(115200);
    while (!Serial) { delay(10); }

    ControlState::begin();
    servos.begin();

    connectWiFi();

    scpi.RegisterCommand("*IDN?", &Identify);
    scpi.RegisterCommand("POS#", &SetPositionN);
    scpi.RegisterCommand("POS#?", &GetPositionN);
    scpi.RegisterCommand("ENABLE", &SetEnabled);
    scpi.RegisterCommand("ENABLE?", &GetEnabled);
    scpi.RegisterCommand("TEST", &SetTest);
    scpi.RegisterCommand("TEST?", &GetTest);

    scpiServer.begin();
    Serial.print(F("[SCPI] Listening on port ")); Serial.println(SCPI_PORT);
}

void loop() {
    // Accept a new client if we don't have one (or the old one dropped).
    if (!scpiClient || !scpiClient.connected()) {
        WiFiClient incoming = scpiServer.accept();
        if (incoming) {
            scpiClient = incoming;
            Serial.println(F("[SCPI] Client connected"));
        }
    }

    if (scpiClient && scpiClient.connected() && scpiClient.available()) {
        scpi.ProcessInput(scpiClient, "\n");
    }

    // Apply the latest commanded positions to the actual hardware every
    // loop -- cheap enough not to bother tracking whether anything changed.
    if (ControlState::getEnabled()) {
        for (uint8_t ch = 0; ch < NUM_SERVOS; ch++) {
            servos.writeDeg(ch, ControlState::getServoPos(ch));
        }
    }
}