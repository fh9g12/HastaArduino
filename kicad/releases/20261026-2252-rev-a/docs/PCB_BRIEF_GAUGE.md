# HastaDAQ strain-gauge board: PCB design brief

For an agent (or person) taking the **gauge-board schematic** to a **PCB layout**. Companion to `docs/PCB_BRIEF.md` (the main board): read that first for the shared conventions (tools, source-of-truth rule, footprint library, workflow); this file only covers what is different. Written 2026-10-25 against schematic rev A.

## 0. Status and hand-off (2026-10-26)

The gauge-board schematic is complete, ERC-clean (0 violations) and committed; **no `.kicad_pcb` exists yet**. All components are chosen (parts and RS numbers in `docs/PARTS_TO_SELECT.md`): MCP1700-3302E/TO LDO (RS 040-3888), 47 uF 16 V RS PRO LHK (RS 707-5758), 10 uF 10 V RS PRO CB tantalum (RS 181-4731), Vishay K-series 100 nF 50 V X7R (RS 181-6552, 2.5 mm lead spacing), standard 1/4 W axial resistors (R5/R6 are the owner's own 350 ohm precision parts), plain 0.1 in pin headers, and ADS122C04 breakouts soldered straight in. A layout agent still needs from the owner: the board outline, mounting holes and connector placement relative to the main board. The fab and design rules are decided (PCBWay, 2 layers, 6/6 mil, 0.3 mm minimum drill, no edge connectors; see `docs/PCB_BRIEF.md` section 0). The loom wiring diagram is `wiring/gauge-loom.yml`. Read `docs/PCB_BRIEF.md` section 0 for the shared decisions and the source-of-truth rule (do not re-run the generator once a PCB exists).

## 1. What this board is

A small, reusable, **through-hole** (hand-soldered) breakout that holds everything about the strain gauges, so the main board does not need to. It sits next to the main board and talks to it over a **4-wire I2C loom** (GND, +5V, SDA, SCL). It could be reused with any I2C master that supplies 5 V and tolerates 3.3 V logic.

| Function | Circuit |
|---|---|
| Loom | J1 (in) and J2 (out, wired in parallel: a pass-through to daisy-chain another I2C board), 1x4 headers: 1=GND, 2=+5V, 3=SDA, 4=SCL (same order as J2 on the main board) |
| Power conditioning | 47 uF C1 + 100 nF C2 on the incoming 5 V (any ferrite bead is part of the loom cable, not on this board), then a 3.3 V LDO (U1, Microchip MCP1700-3302E/TO, TO-92) with 10 uF C3 (tantalum) + 100 nF C4 on its output |
| ADCs | 2 x Adafruit ADS122C04 breakout (U2, U3), I2C, powered from the on-board 3V3 only |
| Gauges | J3, J4: 2x3 half-bridge headers with doubled rows, pins 1,2=+3V3 (V V), 3,4=ADSn_SIG (SIG SIG), 5,6=GND (GND GND) |
| Completion | one shared pair of 350R resistors R5, R6; mid-point `ADS_REF` goes to input A1 of both ADCs |
| Input filter (optional) | per channel: 0R links in series with A0 and A1 (R1/R2 for ADS1, R3/R4 for ADS2) and a DNP 100 nF across A0-A1 (C5 for ADS1, C6 for ADS2) |

How the measurement works: each half-bridge head (two gauges) puts its mid-point on `ADSn_SIG` -> A0; the fixed 350R pair gives the reference mid-point `ADS_REF` -> A1; the ADC measures A0-A1. The ADC's reference is its own supply (`VREF_SUPPLY`), and the same `+3V3` excites the bridges, so the reading is **ratiometric**: supply noise and drift largely cancel. That is why `+3V3` must be clean and why bridge V, the ADC VIN and the completion pair share one local rail.

Owner decisions already made (do not reopen without asking): through-hole only; both ADS breakouts soldered straight to the board (no sockets); 4x1 0.1 in headers for the loom on both boards (keyed plug chosen by the owner when soldering up); regulator on this board from 5 V, with the clean-up hardware here; shared completion pair; footprints in `HastaDAQ.pretty` checked by the owner.

## 2. Where everything is

```
kicad/gaugeboard/gaugeboard.kicad_pro      open in KiCad 10
kicad/gaugeboard/gaugeboard.kicad_sch      the schematic (single sheet, A3). Net-label connectivity.
kicad/gaugeboard/gaugeboard.pdf / .png     pre-rendered copies (re-export after any change)
kicad/gaugeboard/HastaDAQ.kicad_sym        project symbol library (generic blocks)
kicad/gaugeboard/fp-lib-table              points at ../hastadaq/HastaDAQ.pretty (shared footprints)
kicad/tools/generate_gauge_sch.py          bootstrap generator that wrote the schematic
kicad/tools/schgen_common.py               shared helpers
```

The same **source-of-truth rule** applies as on the main board: the generator reassigns reference designators and UUIDs every run, so **once a `.kicad_pcb` exists, do not re-run it**; edit the schematic in KiCad.

Schematic status: **ERC 0 violations** (real pin types, PWR_FLAGs on `+5V` and `GND`). No board file yet. Netlist/ERC commands are as in the main brief, with `kicad/gaugeboard/gaugeboard.kicad_sch`.

## 3. Power

```
J1 pin 2 (+5V) -+-> C1 47 uF, C2 100 nF to GND
                +-> U1 MCP1700 VIN (pin 2)
U1 VOUT (pin 3) -> +3V3 -+-> C3 10 uF, C4 100 nF (at the LDO)
                        +-> U2 / U3 VIN (each breakout has its own 10 uF + 100 nF on VIN)
                        +-> J3 / J4 pins 1 and 2 (bridge V)
```

* **MCP1700-3302E/TO (Microchip, RS 040-3888), TO-92: pin 1 = GND, pin 2 = VIN, pin 3 = VOUT** (data sheet DS20001826C, pin function table; note this is a different pin order from the LP2950 used in the first draft). 3.3 V fixed, 250 mA max, 2.3-6.0 V input (**never feed it more than 6 V**; the loom carries 5 V), about 0.18 V dropout at 250 mA, 1.6 uA quiescent, stable with a 1 uF ceramic, tantalum or aluminium output capacitor. Load here is about 20 mA (two bridges at 3.3 V / 700 ohm = 4.7 mA each, plus the ADCs), so it dissipates about 35 mW from 5 V.
* **Ferrite bead**: not on the board. Any ferrite on the 5 V line is fitted on the loom cable (e.g. a clip-on or a bead on the wire), so it is outside the schematic.
* C1 (47 uF 16 V, RS PRO LHK, 5 x 7 mm) and C3 (10 uF 10 V tantalum, RS PRO CB, case B about 5.0 x 8.0 mm, 2.5 mm lead pitch) are polarised: C1 with + toward `+5V`, C3 with + toward `+3V3` (the tantalum bar marks +). The 100 nF parts (C2, C4, and the DNP filter caps C5/C6) are drawn non-polarised; see the 100 nF open item.
* I2C: the ADS122C04 breakouts carry the pull-ups (10 k on each of SDA and SCL, confirmed from Adafruit's Eagle schematic; two boards give 5 k in parallel, so no extra pull-ups are needed here). The breakouts also carry their own 10 uF + 100 nF on VIN, so no extra ADC decoupling is fitted on this board. The pull-ups go to each breakout's own VIN (= this board's 3V3), so SDA/SCL here are therefore 3.3 V logic; the main board must not drive them above about 3.6 V (the Pico drives 3.3 V). Do not connect a 5 V-pull-up I2C device onto the loom.
* The 5 V pin is not 3V3: the loom is deliberately not Qwiic-compatible. Silkscreen J1 "+5V NOT 3V3", keyed plug. A reversed plug is an accepted risk (it would put +5V on SDA and SCL on GND), so mark pin 1 and the pin order clearly on J1 and J2.

## 4. Net names

`+5V`, `+3V3`, `GND`, `SDA`, `SCL`, `ADS1_SIG`, `ADS2_SIG`, `ADS1_A0`, `ADS1_A1`, `ADS2_A0`, `ADS2_A1`, `ADS_REF`.

One ground net. All sensor connections are a few millimetres from each other; there is nothing to split.

## 5. Connectors and pin maps

* **J1** (loom in) and **J2** (loom out), both `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical`: 1=GND, 2=+5V, 3=SDA, 4=SCL. J2 is wired straight to J1's four pins, adding no circuitry: it passes the +5V and the I2C bus on so another board can be daisy-chained. The same rules apply to it (+5V on pin 2, 3.3 V logic, keyed plug). Keep J1 and J2 close and the stub short, since they share SDA/SCL.
* **J3** (HB1 half-bridge #1, 2x3, odd/even pin numbering, two columns): pins 1,2=+3V3 (V V), 3,4=ADS1_SIG (SIG SIG), 5,6=GND (GND GND). **J4** (HB2): the same with ADS2_SIG. Each row is doubled so that two quarter-bridge gauges (one lead each to V, SIG and GND) can be completed into a half bridge in the plug or on the cable, with no extra terminals; the two pins of a row are the same net on the board. The row order is V, SIG, GND, **different from the main board's servo and SBUS-IN plugs (GND, V, SIG)**, so do not mix the leads up; with SIG in the middle a reversed plug only flips the bridge sign.
* **U2** (ADS122C04 #1): pins used 1=VIN(+3V3), 2=GND, 3=SDA, 4=SCL, 7=A0 (ADS1_A0), 8=A1 (ADS1_A1); RST, DRDY, A2, A3, Ref+, Ref- unconnected. **U3** (ADS122C04 #2) the same with ADS2_A0/A1. Pad numbers follow the module's physical row order (row A: VIN GND SCL SDA DRDY RST; row B: Ref+ A0 A1 A2 A3 Ref-), so numbering looks shuffled; trust the footprint.
* **ADS #2**: bridge the **ADDR0** solder jumper on the back of the breakout (Adafruit's Eagle schematic: ADDR0/ADDR1 are pulled to GND by 10 k, the jumpers tie them to VCC; the expected address is 0x41, not yet confirmed on hardware; the main board's firmware scans at boot).
* **R5, R6** (350R fixed): R5 from `+3V3` to `ADS_REF`, R6 from `ADS_REF` to `GND`, shared by both channels.

## 6. Footprints and parts

The library is the main board's `HastaDAQ.pretty` (via `${KIPRJMOD}/../hastadaq/HastaDAQ.pretty`).

| Part | Footprint | Notes |
|---|---|---|
| U2, U3 ADS122C04 | `HastaDAQ:Adafruit_ADS122C04_Breakout` | Adafruit EagleCAD board file. 25.4 x 17.78 mm; two 1x6 headers 12.7 mm apart; four 2.5 mm holes. |
| U1 MCP1700-3302E/TO | `Package_TO_SOT_THT:TO-92_Inline` | pin 1 GND, 2 VIN, 3 VOUT. Orient the flat face to the footprint outline. |
| J1, J2 | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` | plain 0.1 in header; the owner picks the keyed plug later |
| J3, J4 | `Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical` | doubled rows: V V / SIG SIG / GND GND |

### Parts list (from the schematic)

| Ref | Value / description | Footprint |
|---|---|---|
| C1 | 47uF 16V (RS PRO LHK 5x7) | `Capacitor_THT:CP_Radial_D5.0mm_P2.00mm` |
| C2 | 100nF | `Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm` |
| C3 | 10uF 10V tantalum (RS PRO CB, + to 3V3) | `Capacitor_THT:CP_Radial_D5.0mm_P2.50mm` |
| C4 | 100nF | `Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm` |
| C5 | 100nF, **DNP** (optional filter, ADS1) | `Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm` |
| C6 | 100nF, **DNP** (optional filter, ADS2) | `Capacitor_THT:C_Rect_L4.0mm_W2.5mm_P2.50mm` |
| J1 | LOOM from main board (4-wire I2C): GND, +5V, SDA, SCL | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| J2 | LOOM OUT (pass-through, paralleled with J1) | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| J3 | HB1 half-bridge #1 (on beam), 2x3: V V / SIG SIG / GND GND | `Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical` |
| J4 | HB2 half-bridge #2 (on beam), 2x3: V V / SIG SIG / GND GND | `Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical` |
| R1-R4 | 0R link (input filter positions) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R5, R6 | 350R fixed (completion pair) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| TP1, TP2 | GND and +3V3 test points | `TestPoint:TestPoint_Pad_D2.0mm` (plain pad) |
| U1 | 3.3 V LDO: MCP1700-3302E/TO (TO-92: pin 1 GND, 2 VIN, 3 VOUT) | `Package_TO_SOT_THT:TO-92_Inline` |
| U2 | Adafruit ADS122C04 #1 (I2C 0x40) | `HastaDAQ:Adafruit_ADS122C04_Breakout` |
| U3 | Adafruit ADS122C04 #2 (address jumper bridged) | `HastaDAQ:Adafruit_ADS122C04_Breakout` |

Input filter: with the 0R links fitted and C5/C6 not fitted there is no filter (the original behaviour). To get about an 800 Hz low-pass per channel, fit 1k in each link position (R1+R2 or R3+R4) and 100 nF at C5 (ADS1) or C6 (ADS2). R1/R3 sit in the A0 path (from the gauge SIG), R2/R4 in the A1 path (from `ADS_REF`).

## 7. Layout guidance

* **One solid ground plane**; no separate analog ground. Quiet analog and noisy digital are separated here by the board being small and having no switching circuitry at all: the 5 V goes straight to the LDO.
* Put J1 (loom in) and J2 (loom out) side by side at one end (top left in the placement below) and the gauge headers J3/J4 in the middle band on the left and right sides, so the loom and the gauge cables leave on different sides. All headers are vertical (mated from above); there is no "connector edge".
* Place the LDO U1 and its caps (C1-C4) next to J1. Run `+3V3` from the LDO to both ADCs and to J3/J4 as one short star (the breakouts carry their own decoupling).
* Keep the bridge runs (V, SIG, GND per head) short, side by side, and the SIG traces from J3/J4 -> filter links -> A0 matched in length between the two channels. Keep the shared completion pair R5/R6 close to both ADC inputs, with short matched leads on `ADS_REF` to each A1 (it feeds both channels, so any difference between the two A1 paths shows as a channel offset).
* Keep SDA/SCL short and away from the SIG and `ADS_REF` traces.
* The ADS122C04 breakouts are tall modules plugged in via headers: allow the 25.4 x 17.78 mm footprint plus 2.5 mm mounting holes and keep their top clear of tall parts.
* Gauge cable: shielded twisted pair, shield to GND **at this board only** (the gauge end is left floating).
* Silkscreen: pin 1 on every connector; J1 and J2 pin names (GND, +5V, SDA, SCL) with "+5V NOT 3V3"; J3/J4 pin names (V V / SIG SIG / GND GND, rows doubled); C1 polarity; "ADS2: bridge address jumper"; the optional filter positions (R1-R4, C5, C6) labelled "0R / 1k" and "DNP / 100nF".
**Mechanical guidelines (same as the main board; owner, 2026-10-26; guidelines, not rules).**

* **Mounting:** four M3 holes, one in each corner (3.2 mm non-plated holes, centres about 4 mm in from each edge, copper and parts kept about 6.5 mm clear for the screw head). M3 is the usual default on general PCBs; M2.5 (2.7 mm holes) is the Raspberry Pi convention and only worth using if the enclosure standoffs are already M2.5. Use M3 on both boards so one set of hardware fits both. Round the corners (about 2-3 mm radius).
* **Everything on the top face.** All components and every connector go on the top; nothing on the bottom except solder joints, copper and silkscreen, so the board sits flat on standoffs or a plate. Use standoffs taller than the longest solder-side lead (the Pololu's pins stand 1.4 mm proud), and trim the leads flush.
* **Connectors all face the same way:** vertical 0.1 in headers on the top face, all mated from above, grouped near one end of the board so every cable leaves the same side. (Right-angle headers pointing off an edge are the alternative; that is a footprint swap only, say so if you want it.)

**Gauge board placement (owner, 2026-10-26): modules facing each other, completion resistors between.**

```
          loom J1, J2 (top left)      U2 digital row (VIN GND SCL SDA)   top
          LDO + caps (left)           U2 ANALOG row (A0 A1 ...)  ----+
                                      R5/R6 in the middle,            |  band: C5/R1/R2 + J3 (right)
   J4 (left)  R3/R4/C6                ADS_REF at the centre point     |        C6/R3/R4 + J4 (left)
                                      U3 ANALOG row (A0 A1 ...)  ----+
                                      U3 digital row                     bottom
```

* **Width limit: 60 mm** (owner). The placement is 60 x 70 mm with M3 holes 4 mm in from each corner.
* **Rotation:** U2 is rotated 180 degrees (digital row at the top, analog row facing down) and U3 is not rotated (analog row facing up, digital row at the bottom), so the two analog rows (pads 7-12: Ref+, A0, A1, A2, A3, Ref-) face each other across a central band, and the two modules stand in the same column, about 26 mm wide and 18 mm tall each (courtyards).
* **Point symmetry about the centre of the band.** U3 is U2 turned 180 degrees about that point, so each pad of one module sits exactly opposite its twin. Put the completion pair **R5/R6 on that centre point** (REF ends together at the point, R5 pointing toward the regulator for +3V3, R6 away for GND): the `ADS_REF` leads to the two A1 pins are then equal in length by symmetry. The channel parts are point-symmetric too: channel 1 (C5, R1, R2) in the upper half of the band with J3 at the right, channel 2 (C6, R3, R4) in the lower half with J4 at the left, so the two SIG paths match.
* Keep filter parts and R5/R6 at least 2 mm clear of each module's courtyard (parts must not sit under a breakout).
* The digital rows (power and I2C) face the board's top and bottom edges, away from the analog band; route VIN/GND/SDA/SCL along each module's outer edge.
* J3/J4 are 2x3 headers (5.1 mm x 2.5 mm), the same orientation for both (V V row on top). Their SIG row lines up with the filter link R1 (J3) or R3 (J4).
* LDO U1 and C1-C4 in the left zone below J1/J2; TP1 (GND) and TP2 (+3V3) near them where a probe reaches with the cables plugged in.
* Still not given: the exact enclosure limits and the board's position next to the main board.

## 8. Test points

TP1 (`GND`, for a scope clip) and TP2 (`+3V3`, the regulated rail that powers the ADCs and bridges), both `TestPoint:TestPoint_Pad_D2.0mm` (plain pad). Place them where a probe and clip can reach them with a gauge cable and the loom plugged in. Other nodes are probed at component leads and header pins.

## 9. Known unverified items

* The assembled gauge board has not been built or run. The main-board firmware reads both ADCs over the loom (`Sensors.h`); the I2C addresses, a clean bring-up at 100/400 kHz over the loom, and the second ADC's address are unchecked.
* **100 nF capacitors:** Vishay K series radial MLCC, 100 nF 50 V X7R (RS 181-6552), body about 4 x 4 x 2.6 mm max, 0.5 mm leads; lead spacing 2.5 mm (confirmed from the RS listing; footprint `C_Rect_L4.0mm_W2.5mm_P2.50mm`). Non-polar, so right for C2/C4 (decoupling) and C5/C6 (optional filter, DNP).
* The LDO output is also the bridge excitation: the first thing to check is `+3V3` at the ADCs with an ordinary meter (3.3 V +/- 2 %), and that the readings stay steady when the servos run on the main board.

## 10. Workflow

Same as the main brief section 10, using `kicad/gaugeboard/gaugeboard.kicad_pro`: new board, update from schematic, two layers, ground pour, DRC, Gerbers. Check that J1 here and J2 on the main board have the same pin order (GND, +5V, SDA, SCL) and sit on facing edges, and that the physical keying of the two plugs matches.
