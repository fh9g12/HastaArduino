// StrainGaugeBringup.ino
//
// Bring-up test for a half-bridge strain gauge setup on an Adafruit
// ADS122C04 breakout (https://www.adafruit.com/product/6432): reads the
// bridge output continuously and prints it to Serial. Uses Adafruit's
// own Adafruit_ADS122C04 library (confirmed API/behaviour from the
// actual library source on GitHub, not guessed), not raw I2C register
// pokes -- see arduino-deps.txt for the pinned version.
//
// ---------------------------------------------------------------------
// WIRING -- half bridge (2x 350ohm strain gauges G1/G2 + 2x 350ohm
// fixed completion resistors R1/R2), Wheatstone bridge:
//
//                      EXC+ (VBUS, 5V)
//                     /            \
//                   G1              R1
//                    |               |
//                  OUT+ ----ADS A0   OUT- ----ADS A1 AND ADS REFP
//                    |               |
//                   G2              R2
//                     \            /
//                      EXC- (GND) -------------------- ADS REFN
//
//   Pico Qwiic/STEMMA QT port -> ADS122C04 Qwiic port (3V3/GND/SDA/SCL
//   -- powers the chip's own AVDD at 3.3V; NOT the bridge, see below)
//   Pico VBUS (5V, only present when USB-powered) -> bridge EXC+ (top
//                    rail, both G1/R1) -- kept SEPARATE from ADS122C04's
//                    own VIN/AVDD (3.3V via Qwiic) specifically so the
//                    bridge can run at 5V while the chip stays on its
//                    Qwiic-safe 3.3V supply -- see REFERENCE note below
//                    for why this needs external reference, not VIN-tied
//                    excitation like earlier revisions of this rig used.
//   Bridge EXC- (GND) -> common ground (Pico GND / ADS GND, all one net)
//   Bridge OUT+ (G1/G2 midpoint) -> ADS122C04 A0
//   Bridge OUT- (R1/R2 midpoint) -> ADS122C04 A1 AND ADS122C04 REFP
//                    (double duty -- see REFERENCE note)
//   ADS122C04 REFN -> common ground
//
// IMPORTANT -- this assumes G1 and G2 see OPPOSITE-sign strain (the
// standard "half bridge" configuration: e.g. mounted on opposite faces
// of a bending beam, one in tension while the other's in compression).
// That's what "half bridge" conventionally means in strain-gauge
// terminology (confirmed against HBM/Vishay application notes), and is
// what makes G1/G2 ADD at the bridge output instead of cancelling. If
// your two gauges instead see the SAME-sign strain (e.g. both measuring
// straight axial load on the same face), this wiring will mostly cancel
// -- put one gauge in the G1 position and the other in the R1 position
// instead (i.e. one gauge per bridge leg, not both in the same leg).
//
// EXCITATION/REFERENCE -- deliberately RATIOMETRIC, but NOT via
// VREF_SUPPLY (an earlier revision of this rig used that, back when
// bridge excitation and the ADS122C04's own AVDD were the same 3.3V
// node). Once excitation moved to VBUS (5V) to improve SNR, that's no
// longer true: AVDD stays at 3.3V (Qwiic-supplied), so referencing AVDD
// would no longer track the actual 5V excitation, AND VBUS (raw USB
// power) is not a clean rail the way a regulated supply is -- its noise
// would stop cancelling out.
//
// Also confirmed from the datasheet's absolute maximum ratings: analog
// inputs AND the REFP/REFN pins must stay within AVSS-0.3V to
// AVDD+0.3V (~3.6V here) -- so REFP/REFN can NOT be tied directly to the
// full 5V excitation rail without exceeding that and risking damage.
//
// The fix used here needs zero extra parts: the bridge's OUT- node (the
// R1/R2 midpoint) is a precise, FIXED V_ex/2 tap -- R1/R2 are plain
// resistors, not gauges, so this node doesn't move with strain, only
// with V_ex itself. Wiring OUT- to REFP (in addition to its existing
// A1 connection) and GND to REFN gives a reference that's safely within
// the voltage limit (V_ex/2 ~= 2.5V) AND genuinely proportional to the
// real excitation -- true ratiometric behaviour restored, without
// needing a separate resistor divider. ADC_REFERENCE_VOLTS below
// reflects this V_ex/2 relationship; EXCITATION_VOLTS is the real
// bridge excitation used for the reported mV/V ratio.
// ---------------------------------------------------------------------

#include <Adafruit_ADS122C04.h>

Adafruit_ADS122C04 ads;

// Real bridge excitation (Pico VBUS) -- used ONLY to express the
// reported ratio in standard mV/V-of-excitation terms (see loop()).
const float EXCITATION_VOLTS = 5.0f;

// The ADC's actual external reference voltage -- REFP taps the bridge's
// OUT- node (R1/R2 midpoint, a fixed V_ex/2 tap), REFN is GND, so this
// is exactly EXCITATION_VOLTS/2. See the file header REFERENCE note for
// why this (not EXCITATION_VOLTS directly) is what's safe and correct
// to hand to the library here.
const float ADC_REFERENCE_VOLTS = EXCITATION_VOLTS / 2.0f;

// Max available -- at a 2.5V reference this gives a full-scale range of
// +/-2.5V/128 = +/-19.5mV, comfortably above the +/-1mV bend signal
// this was originally tuned against, with headroom to spare. Watch for
// raw reading near +/-8388607 (clipping) if you apply a much bigger
// bend than whatever you tested with -- drop back to GAIN_64/32 if so.
const ads122c04_gain_t GAIN = ADS122C04_GAIN_128;

// Turbo mode + 90SPS setting = 180 SPS actual -- confirmed from the real
// ADS122C04 datasheet (SBAS751B, Tables 1/5): turbo mode doubles the
// modulator clock along with the output rate, so noise at a given turbo
// rate is essentially the same as normal mode at HALF that rate (NOT a
// noise penalty for the throughput gained, despite what the name
// suggests). 180 SPS is the closest available rate to a 200Hz final
// measurement rate -- there's no exact 200 SPS setting. At gain=128 this
// measures ~0.15uVrms input-referred noise -- ~6500x smaller than the
// +/-1mV signal this was tuned against, so the ADC itself is very
// unlikely to be the dominant noise source at this point; see chat/
// commit history for the other (wiring/EMI/mechanical) noise levers
// this doesn't address.
const bool TURBO_MODE = true;
const ads122c04_rate_t DATA_RATE = ADS122C04_RATE_90SPS; // 90 normal / 180 turbo

// Block average -- cuts random noise by roughly sqrt(N) on top of the
// data rate's own filtering, at the cost of dividing the reported rate
// by N (180SPS / 4 = 45Hz reports here). Set to 1 for the full 180Hz if
// you need the rate more than the extra smoothing -- given how far
// below the signal the ADC's own noise floor already is (see above),
// smaller N is probably fine for a real 200Hz-ish deployment.
const int SAMPLES_TO_AVERAGE = 4;

void setup() {
    Serial.begin(115200);
    while (!Serial && millis() < 3000) { delay(10); } // bounded -- see other .ino files in this repo for why

    Serial.println(F("StrainGaugeBringup -- ADS122C04 half-bridge test"));

    if (!ads.begin()) {
        Serial.println(F("ADS122C04 not found -- check wiring/I2C address."));
        while (1) { delay(10); }
    }

    ads.setMux(ADS122C04_MUX_AIN0_AIN1); // AINP=A0=bridge OUT+, AINN=A1=bridge OUT-
    ads.setGain(GAIN);
    ads.enablePGA(true); // required for gain >1 in differential mode -- see library source
    ads.setVoltageReference(ADS122C04_VREF_EXTERNAL); // REFP=bridge OUT-, REFN=GND -- see header note
    ads.setReferenceVoltage(ADC_REFERENCE_VOLTS);
    ads.setContinuousMode(true);
    ads.setTurboMode(TURBO_MODE);
    ads.setDataRate(DATA_RATE);

    ads.startSync();
    Serial.println(F("Reading..."));
}

float sumVoltage = 0.0f;
float sumRatio = 0.0f;
int sampleCount = 0;

void loop() {
    if (!ads.isDataReady()) return;

    int32_t raw = ads.readData();
    if (raw == 0xEE000000) {
        Serial.println(F("ADC read error"));
        return;
    }

    float voltage = ads.convertToVoltage(raw); // absolute bridge output volts (correct regardless of reference scheme)
    sumVoltage += voltage;
    sumRatio += (voltage / EXCITATION_VOLTS) * 1000.0f; // mV per V of the REAL excitation, not the (halved) ADC reference
    sampleCount++;

    if (sampleCount < SAMPLES_TO_AVERAGE) return;

    Serial.print(F("bridge="));
    Serial.print((sumVoltage / sampleCount) * 1000.0f, 4);
    Serial.print(F(" mV  ratio="));
    Serial.print(sumRatio / sampleCount, 5);
    Serial.println(F(" mV/V"));

    sumVoltage = 0.0f;
    sumRatio = 0.0f;
    sampleCount = 0;
}
