# HastaDAQ_v2 firmware: outstanding tasks (2026-10-28)

State: `HastaDAQ_v2` compiles for the REV A pin map, but **none of it has run on the finished board**. Both PCBs were ordered from
PCBWay (gauge 2026-10-27, main 2026-10-28; `kicad/releases/rev-a/`). This list collects what is still open; the longer
discussion of each is in `docs/README.md` ("Open items and unverified assumptions") and `docs/PCB_BRIEF.md` section 9.

The pin map was cross-checked against the routed main board (Pico pad nets read from `hastadaq.kicad_pcb`): ENC1-3 chip-selects
GP13/GP9/GP8, SPI GP10-GP12, SSI clock GP17 and data GP18/GP19, trigger in/out GP14/GP15, soft stop GP16, SBUS in GP1,
SBUS out GP20/GP21 all match `EncoderPorts.h` and the sketch header.

## Not written

- [ ] **SBUS pass-through** (RC receiver -> Pico -> servos). Hardware is ready (J10, GP1 = UART0 RX). SBUS is 100 kbaud 8E2,
  inverted: `Serial1.setInvertRX(true)`. See the comment in `HastaDAQ_v2.ino`.

## Written, never run on hardware (first bench session)

- [ ] **RM08 SSI driver** (`HastaDrivers/src/Rm08Ssi.h`, `.pio`): only assembled and compiled. Frame layout inferred from the
  owner's ESP32 sketch, clock edge assumed (SPI mode 2 style). Check: scope on `SSI_CLK` / `SSI1_DATA`, then `ENCODERS?` shows
  `valid:true` and an angle that follows the shaft. Requirement: at least 100 Hz per encoder (polled every 1 ms at 500 kHz).
- [ ] **Orbis SPI mode** (`OrbisEncoder.h`): mode 1 is inferred. If readings are garbage try mode 3 / 0. CRC not checked.
- [ ] **Soft stop** (GP16, closed loop = low = run) and **trigger polarity** both ways (GP14 in, GP15 out).
- [ ] **TRIG_OUT power-up glitch**: the open-collector output floats until firmware starts; measure it.
- [ ] **Two SPI devices on one MISO**: data sheets say Hi-Z when deselected; not measured.
- [ ] **Second ADS122C04 address**: expected 0x41 (ADDR0 jumper bridged); boot-time I2C scan is the fallback.
- [ ] **I2C over the gauge-board loom**: untested; check edges if the loom is lengthened.
- [ ] **R14 (SBUS IN pull-down)** is left unfitted: check the idle level of `SBUS_IN_GPIO` with no receiver; if it floats, fit
  4.7 k (RP2350 erratum E9) rather than 10 k.
- [ ] **Default encoder types** (`ENC_DEFAULT_TYPES` in `EncoderPorts.h`): only ENC1 = MT6835 by default, SSI ports = RM08.
  Edit to match what is plugged in, or send `ENCCONFIG` after boot.
- [ ] **MATLAB client** (`matlab/hastadaq`): the 84-byte sample layout with the four extra encoder channels
  (`DaqData.m`, `NumExtraEncoders`) and the client as a whole are not yet run against a live board.

## Open from before the new board

- [ ] **Build target**: "Pimoroni PicoPlus2W" vs `pimoroni_pico_plus_2`; which works at runtime is not re-checked.
- [ ] **Intermittent "no reply"** on long runs: cause unknown (`SYS?`, Serial log, client `ReconnectCount` exist to find it).
- [ ] **SBUS count-to-microsecond factor** (0.625 us/count, 1024 = 1520 us) is assumed, not measured.
- [ ] **RP2350 5 V tolerance** of the trigger-in pin is unconfirmed (the new board's opto stage keeps it at 3.3 V).
- [ ] **Stale artefacts**: the WireViz files in `wiring/` predate the channel reorder and power connector; re-export.

## Keep in mind

- `HastaDAQ` (the original-board firmware) is unchanged and still the known-good one for the old board.
- The routed board and the Pico footprint edits (antenna keep-out trimmed, Pololu holes removed) do not affect the firmware.
