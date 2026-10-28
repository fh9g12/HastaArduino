#pragma once
#include <Arduino.h>
#include <PIOProgram.h> // arduino-pico helper: finds a free PIO block + state machine and loads the program
#include <hardware/pio.h>
#include <hardware/clocks.h>
#include "Rm08Ssi.pio.h"

// Driver for TWO RLS RM08 encoders (SSI output, 12-bit, "RM08SC...") read by ONE PIO state machine: one shared
// clock output and two data inputs on consecutive GPIOs, both data lines sampled on the same clock edge. The
// encoders are used through an inline LDB02 line-driver board that the owner places near the Pico, so this code
// only sees the single-ended 3.3 V side: CLK out, DATA in (see HastaDAQ v2's schematic, headers SSI1 / SSI2).
//
// Why PIO and not bit-banging: the RM08 aborts a frame if the clock pauses mid-frame for longer than its
// monoflop time (data sheet RM08D01_18: 12.5 us <= tm <= 20.5 us), and this firmware also runs WiFi, SBUS and
// interrupts. The PIO state machine keeps the clock timing exact whatever the CPU is doing, costs no CPU time and
// latches both encoders at the same instant.
//
// FRAME (from the owner's working ESP32 sketch, SPI mode 2, 500 kHz, 32 clocks; NOT checked against a timing
// diagram: the data sheet's SSI timing diagram is a graphic that could not be read, see below):
//   clock idles high; each of the 32 clocks is sampled on its falling edge;
//   bit 0      = 1  (the idle level of the data line at the first falling edge)
//   bits 1-12  = 12-bit position, MSB first, natural binary (4096 counts per turn)
//   bit 13     = error flag, 0 = OK
//   bits 14-25 = the position again (the encoder re-sends its ring register while clocks continue)
// A frame is accepted only if bit 0 = 1, bit 13 = 0 and the two copies of the position are equal -- the same rule
// as the owner's sketch. An unplugged data line (10 k pull-up on the board) reads all ones, so bit 13 = 1: rejected.
//
// TIMING: SM clock = 8 x the SSI clock (every instruction is 4 SM cycles, high and low). After the 32nd clock the
// clock stays high for 257 SM cycles (32 us at 1 MHz, 64 us at 500 kHz), above the 20.5 us monoflop maximum, before
// the next frame can be started. Data sheet: clock <= 4 MHz.
//
// NOT VERIFIED ON HARDWARE (nothing here has run on a Pico yet): the frame layout is inferred from the sketch above,
// the clock edge assumed from SPI mode 2, and the PIO program has only been assembled and compiled. First checks:
// put a scope on SSI_CLK / SSI1_DATA, then `ENCODERS?` should show valid:true and an angle that follows the shaft.
//
// API mirrors OrbisEncoder / Mt6835Encoder (continuous unwrapped angle, software zero, saved-zero pair), per channel.
// update() never blocks: it collects a finished frame and starts the next one.
class Rm08Ssi {
public:
    static const uint8_t NUM_CH = 2;

    // clkPin = shared clock output; data1Pin = DATA1 input; DATA2 is the next GPIO (data1Pin + 1). clockHz <= 4 MHz.
    // Returns false if no free PIO state machine could be claimed. Safe to call more than once (later calls do nothing).
    bool begin(uint8_t clkPin, uint8_t data1Pin, uint32_t clockHz = 500000) {
        if (_ready) return true;
        _prog = new PIOProgram(&rm08_ssi_program);
        const uint8_t lo = min(clkPin, data1Pin), hi = max(clkPin, (uint8_t)(data1Pin + 1));
        if (!_prog->prepare(&_pio, &_sm, &_offset, lo, hi - lo + 1)) return false;

        if (clockHz > 4000000) clockHz = 4000000;
        _clkMask = 1u << clkPin;
        pio_sm_config c = rm08_ssi_program_get_default_config(_offset);
        sm_config_set_sideset_pins(&c, clkPin);
        sm_config_set_in_pins(&c, data1Pin);
        sm_config_set_in_shift(&c, false, true, 32); // shift left, autopush every 32 bits (= 16 clocks)
        sm_config_set_clkdiv(&c, (float)clock_get_hz(clk_sys) / (8.0f * (float)clockHz));

        // Drive the clock pin HIGH before the PIO owns the pin, so the encoders never see a falling edge at start-up.
        pio_sm_set_pins_with_mask(_pio, _sm, _clkMask, _clkMask);
        pio_sm_set_pindirs_with_mask(_pio, _sm, _clkMask, _clkMask);
        pio_gpio_init(_pio, clkPin);
        pio_gpio_init(_pio, data1Pin);
        pio_gpio_init(_pio, data1Pin + 1);
        pio_sm_set_consecutive_pindirs(_pio, _sm, data1Pin, 2, false); // DATA1, DATA2 = inputs
        _startPc = _offset;
        pio_sm_init(_pio, _sm, _offset, &c);
        pio_sm_set_enabled(_pio, _sm, true);

        _ready = true;
        _inFlight = false;
        _startUs = micros() - MIN_PERIOD_US;
        // Take one frame now (a few hundred microseconds at most) so valid() means something straight away.
        const uint32_t t0 = micros();
        do { update(); } while (!_haveFrame && micros() - t0 < 3000);
        return true;
    }

    bool ready() const { return _ready; }

    // Call often (EncoderPorts calls it every poll). Collects a finished frame if there is one, then starts the next.
    void update() {
        if (!_ready) return;
        const uint32_t now = micros();
        if (_inFlight) {
            if (pio_sm_get_rx_fifo_level(_pio, _sm) >= 2) {
                const uint32_t w0 = pio_sm_get(_pio, _sm);
                const uint32_t w1 = pio_sm_get(_pio, _sm);
                decode(w0, w1);
                _inFlight = false;
                _haveFrame = true;
            } else if (now - _startUs > FRAME_TIMEOUT_US) {
                recover(); // should never happen: the state machine is autonomous
                for (uint8_t i = 0; i < NUM_CH; i++) { _ch[i].valid = false; _ch[i].fail++; }
                _inFlight = false;
            }
        }
        if (!_inFlight && now - _startUs >= MIN_PERIOD_US) {
            if (!pio_sm_is_tx_fifo_full(_pio, _sm)) {
                pio_sm_put(_pio, _sm, 0); // any word starts one frame
                _startUs = now;
                _inFlight = true;
            }
        }
    }

    // ---- per channel (0 = SSI1 / DATA1, 1 = SSI2 / DATA2) ----
    bool valid(uint8_t ch) const { return ch < NUM_CH && _ch[ch].valid; }
    uint32_t failCount(uint8_t ch) const { return ch < NUM_CH ? _ch[ch].fail : 0; }
    // Raw 32-bit frame of the last frame (accepted or not), MSB = first clock: for bench debugging.
    uint32_t lastFrame(uint8_t ch) const { return ch < NUM_CH ? _ch[ch].frame : 0; }
    // Last accepted 12-bit position (0..4095).
    uint16_t lastCounts(uint8_t ch) const { return ch < NUM_CH ? _ch[ch].counts : 0; }

    // Continuous (unwrapped) angle in degrees relative to the last zero; NaN until a first frame has been accepted.
    float getDegrees(uint8_t ch) const {
        if (ch >= NUM_CH || !_ch[ch].primed) return NAN;
        return _ch[ch].continuousDeg - _ch[ch].zeroOffsetDeg;
    }
    void zeroAtCurrentPosition(uint8_t ch) { if (ch < NUM_CH) _ch[ch].zeroOffsetDeg = _ch[ch].continuousDeg; }

    // Raw absolute angle [0,360) that currently reads as 0 deg (same save/re-apply scheme as the other encoders).
    float zeroOffsetRawDegrees(uint8_t ch) const {
        if (ch >= NUM_CH) return NAN;
        float zero = fmodf(_ch[ch].lastRawDeg - (_ch[ch].continuousDeg - _ch[ch].zeroOffsetDeg), 360.0f);
        if (zero < 0.0f) zero += 360.0f;
        return zero;
    }
    void setZeroOffsetRawDegrees(uint8_t ch, float zeroRawDeg) {
        if (ch >= NUM_CH) return;
        float delta = fmodf(_ch[ch].lastRawDeg - zeroRawDeg, 360.0f);
        if (delta > 180.0f) delta -= 360.0f;
        else if (delta <= -180.0f) delta += 360.0f;
        _ch[ch].zeroOffsetDeg = _ch[ch].continuousDeg - delta;
    }

    // Decodes one frame (the 32-bit value, MSB = first clock). Public and static so it can be unit-checked off-target.
    // Returns true and the 12-bit position if the frame passes the checks described at the top.
    static bool checkFrame(uint32_t f, uint16_t& counts) {
        const bool start = (f >> 31) & 1u;
        const uint16_t v1 = (f >> 19) & 0xFFFu;  // clocks 1..12
        const bool err = (f >> 18) & 1u;         // clock 13
        const uint16_t v2 = (f >> 6) & 0xFFFu;   // clocks 14..25
        counts = v1;
        return start && !err && v1 == v2;
    }

private:
    static const uint32_t MIN_PERIOD_US = 100;      // frame + gap are about 100 us at 500 kHz; never start sooner
    static const uint32_t FRAME_TIMEOUT_US = 3000;  // a frame is a fraction of this: longer means something is wrong

    struct Chan {
        bool valid = false;
        bool primed = false;
        uint32_t fail = 0;
        uint32_t frame = 0;
        uint16_t counts = 0;
        float lastRawDeg = 0.0f, continuousDeg = 0.0f, zeroOffsetDeg = 0.0f;
    };

    // Two words -> two 32-bit frames. Each clock c contributed a 2-bit pair (bit1 = DATA2, bit0 = DATA1); word 0 holds
    // clocks 0..15 with clock 0 in bits 31:30, word 1 holds clocks 16..31.
    void decode(uint32_t w0, uint32_t w1) {
        uint32_t f[NUM_CH] = {0, 0};
        for (uint8_t c = 0; c < 32; c++) {
            const uint32_t w = (c < 16) ? w0 : w1;
            const uint32_t pair = (w >> (2 * (15 - (c & 15)))) & 3u;
            f[0] = (f[0] << 1) | (pair & 1u);
            f[1] = (f[1] << 1) | ((pair >> 1) & 1u);
        }
        for (uint8_t i = 0; i < NUM_CH; i++) {
            Chan& ch = _ch[i];
            ch.frame = f[i];
            uint16_t counts;
            if (!checkFrame(f[i], counts)) {
                ch.valid = false;
                ch.fail++;
                continue;
            }
            ch.valid = true;
            ch.counts = counts;
            const float rawDeg = (float)counts / 4096.0f * 360.0f;
            if (!ch.primed) {
                ch.lastRawDeg = rawDeg;
                ch.continuousDeg = rawDeg;
                ch.primed = true;
                continue;
            }
            float delta = rawDeg - ch.lastRawDeg;
            if (delta > 180.0f) delta -= 360.0f;
            else if (delta < -180.0f) delta += 360.0f;
            ch.continuousDeg += delta;
            ch.lastRawDeg = rawDeg;
        }
    }

    // Stop, flush and restart the state machine at the top of the program, with the clock held high.
    void recover() {
        pio_sm_set_enabled(_pio, _sm, false);
        pio_sm_clear_fifos(_pio, _sm);
        pio_sm_restart(_pio, _sm);
        pio_sm_set_pins_with_mask(_pio, _sm, _clkMask, _clkMask);
        pio_sm_exec(_pio, _sm, pio_encode_jmp(_startPc));
        pio_sm_set_enabled(_pio, _sm, true);
    }

    PIOProgram* _prog = nullptr;
    PIO _pio = nullptr;
    int _sm = -1;
    int _offset = 0;
    uint _startPc = 0;
    uint32_t _clkMask = 0;
    bool _ready = false;
    bool _inFlight = false;
    bool _haveFrame = false;
    uint32_t _startUs = 0;
    Chan _ch[NUM_CH];
};
