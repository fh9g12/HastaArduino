# Parts still to select (REV A, both boards)

Every component that needs a specific orderable part before the PCBs are laid out (the footprint depends on the real part for the ones marked **fp**). Updated 2026-10-26 from the two schematics (`kicad/hastadaq`, `kicad/gaugeboard`). All parts are through-hole. Decisions so far: no fuse (the bench supply's current limit protects), every connector is a plain 0.1 in (2.54 mm) pin header (the owner chooses keyed plugs later), test points are plain copper pads, the Pico, Pololu, BabyBuck and both ADS boards are soldered straight to the PCB (no sockets), and resistors are standard 1/4 W axial parts.

## A. Main board (`kicad/hastadaq`)

### Chosen (RS)

| Ref | Part | RS | Footprint in schematic | Check |
|---|---|---|---|---|
| D2 | Taiwan Semi BZX55C5V1 R0, 5.1 V zener, 500 mW, 6 %, DO-35 | 748-5051 | `D_DO-35_SOD27_P7.62mm_Horizontal` | DO-35 fits |
| U4 | onsemi **FOD817A** opto-coupler, 4-pin DIP, CTR 80-160 % | 761-4439 | `DIP-4_W7.62mm` | pin-compatible with PC817 (1 anode, 2 cathode, 3 emitter, 4 collector) |
| D1 | STMicroelectronics **1N5822** Schottky, 3 A, 40 V, DO-201AD (data sheet from RS: VF 0.525 V max at 3 A) | 687-0877 | `D_DO-201AD_P15.24mm_Horizontal` | body 9.5 mm long x 5.3 mm diameter, lead 1.3 mm diameter: matches the KiCad footprint |
| D3 | Vishay **BAV17-BAV21** family switching diode, DO-35, I(F) 250 mA (any member works: V(RRM) 25-250 V) | 700-3863 | `D_DO-35_SOD27_P7.62mm_Horizontal` | meets the D3 requirements below; confirm the exact type on the RS page |

### Bulk capacitors: chosen (dimensions from the RS data sheets)

| Ref | Part | RS | Body (D x L) | Lead pitch | Footprint in schematic |
|---|---|---|---|---|---|
| C1 (12 V input bulk) | Panasonic **ECA1EM101**, 100 uF 25 V, M-A series, 85 C | 075-9069 | 6.3 x 11.2 mm | 2.5 mm | `CP_Radial_D6.3mm_P2.50mm` |
| C2 (servo rail 8.4 V bulk) | Panasonic **EEUFR1C471**, 470 uF 16 V, FR-A series (low ESR, 105 C, 950 mA ripple) | 708-3620 | 8.0 x 11.5 mm | 3.5 mm | `CP_Radial_D8.0mm_P3.50mm` |
| C3 (5 V bulk near the Pico) | RS PRO **LHK** 100 uF 10 V, 105 C (80 mA ripple) | 707-5799 | 5 x 7 mm | 2.0 mm | `CP_Radial_D5.0mm_P2.00mm` |

Assignment note: the three titles you sent were labelled C1 = 100 uF 25 V, C2 = 100 uF 10 V, C3 = 470 uF 16 V. I assigned them by function: the servo rail (8.4 V, five servos) needs the 470 uF 16 V part, and the 5 V rail takes the 100 uF 10 V part (10 V on a 5 V rail is a 2x margin; 16 V on 8.4 V is 1.9x; 25 V on 12 V is 2x). Check that your order matches this. The LHK part's 80 mA ripple rating is small, which is fine for local bulk beside the BabyBuck's own 2 x 22 uF ceramic.

### D3 (1N4148-class): selection criteria (BAV17-BAV21 chosen)

D3 sits antiparallel across the opto LED, so it only carries the LED current when the trigger is connected backwards. It does not need to be fast or high-voltage. Search RS for a through-hole **small-signal / switching diode** (or a rectifier diode) and filter on:

- **Mounting:** through hole; **package** DO-35 (or DO-34; DO-41 is bigger and needs a footprint change).
- **Forward current I(F):** at least 100 mA (150-200 mA is typical). The worst case is about 24 mA, from a 24 V reverse connection through the 1 k.
- **Reverse voltage V(R):** 30 V or more is plenty (it only sees the LED's forward voltage, about 1.2 V, in normal use); 75-100 V is what a 1N4148 gives.
- **Speed:** irrelevant (anything from a 1N4148 to a 1N4007 works); ignore reverse recovery time.
- **Pack size:** pick a bag or strip of 25-100 rather than a 2000-piece reel.
- **Equivalent types:** 1N4148, 1N4448, 1N914, 1N4151; or a rectifier diode such as 1N4001-1N4007 (DO-41, 1 A), which RS sells in small packs but would need the D3 footprint changed to DO-41. A small through-hole Schottky also works.

### Still to choose

| Ref | Qty | What | Constraints from the schematic | Footprint | fp |
|---|---|---|---|---|---|
| R8 | 1 | 1 k, 1 W axial | 1 W (24 V trigger gives about 0.6 W); body about 9.9 x 3.6 mm | `R_Axial_DIN0411_L9.9mm_D3.6mm_P12.70mm_Horizontal` | **fp** |
| R1-R4, R6, R7, R9, R11, R14 | 9 | 10 k, 1/4 W | standard axial, body about 6.3 x 2.3 mm | `R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` | |
| R5, R13 | 2 | 1 k, 1/4 W | same | same | |
| R10 | 1 | 2.2 k, 1/4 W | base resistor | same | |
| R12 | 1 | 1.5 k, 1/4 W | TRIG_OUT pull-up (about 8 mA at 12 V) | same | |

The 0207 footprint covers a 6.3 x 2.3 mm body (it is drawn for 6.3 x 2.5 mm) at 7.62 mm lead pitch. If you stand the resistors up or want a tighter pitch, say so and the footprint changes.

### Connectors: all plain 0.1 in pin headers (nothing more to decide for layout)

| Ref | Pins | Notes |
|---|---|---|
| J1 | 1x4 | IMU (GND, 3V3, SDA, SCL) |
| J2 | 1x4 | gauge-board loom (GND, +5V, SDA, SCL) |
| J3-J6 | 2x4 each | encoder ports ENC1-ENC4 |
| J7 | 3x6 | six servo plugs (GND, V, SIG); custom footprint, same 2.54 mm grid |
| J8 | 2x4 | main supply cable (12 V, GND, triggers, soft stop) |
| J9 | 2x3 | TRIG_OUT pull-up select, plus one shunt jumper |
| J10 | 1x3 | SBUS IN |

### Nothing to buy for layout

- TP1, TP2: plain 2.0 mm copper pads (`TestPoint_Pad_D2.0mm`).
- U1 Pico Plus 2, U2 Pololu D42V55F8, U3 BabyBuck: soldered straight to the PCB (no sockets), using the module footprints already in the schematic.
- Q1 2N3904: already chosen (RS).

## B. Gauge board (`kicad/gaugeboard`)

### Chosen

| Ref | Part | RS | Footprint in schematic | Check |
|---|---|---|---|---|
| U1 | Microchip **MCP1700-3302E/TO**, 3.3 V LDO, 250 mA, TO-92 | 040-3888 | `TO-92_Inline` | TO-92 pin 1 GND, 2 VIN, 3 VOUT (data sheet DS20001826C); input max 6.0 V, so only the 5 V loom may feed it |
| C1 | RS PRO 47 uF 16 V aluminium electrolytic (LHK series, 5 x 7 mm, 2.0 mm pitch) | 707-5758 | `CP_Radial_D5.0mm_P2.00mm` | polarised: + to `+5V` |
| C3 | RS PRO 10 uF 10 V solid tantalum (CB series, case B about 5.0 x 8.0 mm, 2.5 mm pitch) | 181-4731 | `CP_Radial_D5.0mm_P2.50mm` | polarised: + (bar) to `+3V3`; now drawn as a polarised capacitor |
| R1-R6 | standard 1/4 W axial resistors (0 ohm links, and the owner's 350 ohm precision parts for R5/R6) | | `R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` | |
| J1-J4 | plain 0.1 in pin headers (J1, J2 = 1x4 loom, J3, J4 = 1x3 half-bridge) | | `PinHeader_1x04` / `PinHeader_1x03` | |
| U2, U3 | Adafruit ADS122C04 breakouts, soldered straight to the PCB | | `HastaDAQ:Adafruit_ADS122C04_Breakout` | |
| TP1, TP2 | plain 2.0 mm pads | | `TestPoint_Pad_D2.0mm` | |

### 100 nF capacitors (C2, C4, C5, C6): chosen

Vishay **K series radial multilayer ceramic**, 100 nF, 50 V, +/-10 % X7R, **RS 181-6552**. Size code 15 (the RS listing gives 2.6 mm width; body 4.0 x 4.0 x 2.6 mm max), 0.5 mm leads, **lead spacing 2.5 mm (confirmed)**. Footprint `Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm`. Non-polar, so it is also right for the filter positions C5/C6 (DNP).

For a 24-bit filter in the signal path (C5/C6, only if fitted) a film or C0G part would be slightly better than X7R, which has some voltage dependence and microphonics; the K series C0G tops out at 10 nF.

## C. Already chosen (no action, just buy)

| Item | Note |
|---|---|
| Pimoroni Pico Plus 2 + RM2 breakout | RM2 is cabled off-board to the SP/CE connector (JST-SH 8-pin lead) |
| Pololu D42V55F8 (8.4 V, 5 A) | 6.1 mm tall |
| SparkFun BabyBuck 5V (AP63357) | EN open is supported by the data sheet |
| 2N3904 (Q1) | TO-92, pin 1 E, 2 B, 3 C |
| FOD817A (U4), BZX55C5V1 (D2) | RS 761-4439, RS 748-5051 |
| 2 x Adafruit ADS122C04 breakouts | 10 k I2C pull-ups on each board |
| Adafruit ICM20649 + Pi Hut Qwiic breakout 106676 | off-board |
| Encoders (MT6835 breakouts, RLS Orbis) | off-board |
| Servos, SBUS receiver | off-board |

## D. Off-board and assembly items to source (not in the schematics)

- **Mating plugs and cable** for each header (keyed/shrouded plugs are the owner's choice, since a rotated encoder or supply plug puts 5 V or 12 V on a wrong pin): encoder and supply cables, the loom plugs and wire (GND, +5V, SDA, SCL), servo plugs, the SBUS IN lead, a shunt jumper for J9.
- **Ferrite** for the +5V wire of the loom (clip-on or a bead on the wire); it is not on either PCB.
- **Gauge cable:** shielded twisted pair, shield to GND at the gauge board only.
- **Mounting:** M3 standoffs/screws once the board outlines and mounting holes are drawn.
- A 12 V supply lead for J8. There is no fuse on the board: set the bench supply's current limit (about 3 A).

## E. Still open before layout starts

Confirmed by the owner from the RS listings on 2026-10-26: C2 main (RS 708-3620) 8 mm diameter, 3.5 mm lead pitch; C3 main (RS 707-5799) 2.0 mm pitch; gauge C3 tantalum (RS 181-4731) 2.5 mm pitch. The R8 (1 W resistor) footprint assumption and the through-hole Pico Plus 2 footprint are accepted.

1. **Part details:** none outstanding (the 100 nF lead spacing is confirmed at 2.5 mm).
2. **Mechanical inputs (not in the schematics):** board outlines, mounting holes, which edge each connector sits on, and how the two boards sit side by side (the loom headers J2 on the main board and J1 on the gauge board face each other). Also enclosure limits, USB-C and RM2 cable clearance, and the Pololu's 6.1 mm height.
3. **Fabrication:** which fab, copper weight (1 oz suggested), minimum track/space and drill sizes, 2 layers at 1.6 mm. The design rules and net classes get set from this.
4. **Process step:** open both schematics in KiCad, check annotation, and from then on edit them in KiCad (stop re-running the generators once a `.kicad_pcb` exists).
5. **Bench checks that could still force a respin (see the briefs' unverified-items lists):** ADS #2 address (expected 0x41), I2C over the loom, Orbis SPI mode, soft-stop and trigger polarity, TRIG_OUT level at power-up.
