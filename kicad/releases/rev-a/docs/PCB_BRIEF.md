# HastaDAQ REV A: PCB design brief (main board)

For an agent (or person) taking the finished **schematic** to a **PCB layout**. Read this first, then `docs/README.md` ("Schematics, wiring and library management" and "Open items") for the wider project. Written 2026-10-25 against schematic rev A.

**There are two boards.** This brief covers the **main board** (`kicad/hastadaq/`). The strain-gauge hardware (two ADS122C04 ADCs, the half-bridge headers, completion resistors, its own 3.3 V regulator and filtering) is a separate, reusable **gauge board** (`kicad/gaugeboard/`, brief in `docs/PCB_BRIEF_GAUGE.md`). The boards sit next to each other and are joined by a 4-wire I2C loom (section 5, J2). Lay them out as two independent PCBs.

## 0. Status and hand-off (2026-10-26)

**State:** both schematics (main `kicad/hastadaq`, gauge `kicad/gaugeboard`) are complete, ERC-clean (0 violations) and committed. **No `.kicad_pcb` exists yet.** Every component has been chosen and its footprint checked against the vendor data sheet (see `docs/PARTS_TO_SELECT.md` for the part and RS stock numbers). What a layout agent still needs from the owner, because it is not in the repository:

1. **Mechanical:** the owner's placement and mounting guidelines are in section 7 (M3 corner holes, everything on top, all connectors the same way, portrait main board with the USB-C at the top). Still needed: the exact board outlines, enclosure limits, USB-C and RM2 cable clearance, and how the two boards sit side by side (main J2 and gauge J1 loom headers face each other).
2. **Fabrication (decided 2026-10-26): PCBWay, standard 2-layer service, 10 boards.** 2 copper layers, 1.6 mm FR4, 1 oz copper, no edge connectors (no gold fingers). Design rules: **minimum track and spacing 6/6 mil (0.152 mm)**, minimum drill 0.3 mm (the through-hole parts here use 1.0 mm or larger, so this is never the limit), use wider tracks and more clearance wherever there is room (power: section 3; trigger lines: section 5). Check these against PCBWay's current capabilities page before ordering. PCBWay's cheapest quote tier is up to 100 x 100 mm, so aim to keep each board within that if the modules allow (the Pico Plus 2 alone is 51 x 21 mm). Set these as the board's minimums in Board Setup and the DRC.

**Decisions already made by the owner (do not reopen):** supply input is 12 V nominal, **20 V maximum** (limited by C1's 25 V rating; no TVS, the bench supply's current limit and setpoint are the protection); SBUS IN is powered from `+5V` (the receiver is a Futaba R3008SB, 4.8-7.4 V) with a 5.1 V zener clamp; J9 is a 1x5 shunt-safe header; an unkeyed reversed loom plug is an accepted risk (silkscreen marking only); through-hole only; no fuse (the bench supply's current limit protects); every connector is a plain 0.1 in pin header (keyed plugs are chosen later; pin numbering equals the keyed IDC box header); test points are plain 2.0 mm pads; the Pico Plus 2, Pololu, BabyBuck and both ADS122C04 breakouts are soldered straight to the board (no sockets); resistors are standard 1/4 W axial parts (R8 is 1 W); strain-gauge hardware lives on its own board with its own 3.3 V regulator; the loom is GND, +5V, SDA, SCL at 2.54 mm pitch.

**Source-of-truth reminder:** the generators (`kicad/tools/generate_hastadaq_sch.py`, `generate_gauge_sch.py`, `schgen_common.py`) wrote the schematics and reassign reference designators on every run; once a `.kicad_pcb` exists, edit the schematics in KiCad and never re-run them.

**Verification facts gathered from data sheets (not just assumed):** BabyBuck (AP63357, Diodes DS41949) EN may be left open (internal pull-up) or tied to VIN (35 V abs max); Adafruit ADS122C04 breakouts carry 10 k I2C pull-ups on SDA/SCL, ADDR pulled to GND by 10 k (default 0x40, ADDR0 jumper expected 0x41); MCP1700 TO-92 pinout is 1 GND, 2 VIN, 3 VOUT (6.0 V max input); RS product pages could not be fetched automatically, so part dimensions come from the linked RS data sheets and the owner's confirmation.

**Not yet verified on hardware:** see section 9.

## 1. What this board is

HastaDAQ is a bench/wind-tunnel instrument for a model aircraft. One Pimoroni **Pico Plus 2** (RP2350B, USB-C) runs the firmware (`HastaDAQ_v2/`), and talks WiFi through a **Pimoroni RM2 breakout that is cabled to the Pico's SP/CE connector and is NOT on this PCB**. The PCB is a **through-hole carrier** (hand-soldered, no SMD) that plugs together ready-made modules and adds a small amount of discrete circuitry:

| Function | Module / circuit |
|---|---|
| Controller | Pico Plus 2 on 2 x 20 pins (stock footprint `Module:RaspberryPi_Pico_Common_THT`) |
| Strain gauges | **Not on this board.** J2 is a 1x4 loom header (GND, +5V, SDA, SCL) to the gauge board |
| IMU | Adafruit ICM20649 on a separate board; a 1x4 header (J1) carries GND/3V3/SDA/SCL (optionally via The Pi Hut Qwiic breakout 106676) |
| Servo power | Pololu D42V55F8 buck, 12 V in -> fixed 8.4 V, 5 A (`VSERVO`) |
| Logic power | SparkFun BabyBuck 5V (AP63357) -> `+5V` -> Schottky -> Pico VSYS |
| Servo bus | One 3x6 header, six servo plugs (SBUS, all signals in parallel) |
| SBUS in | One 3-pin header (J10) for an RC receiver's SBUS output, for a pass-through mode; powered from `+5V` (the Futaba R3008SB takes 4.8-7.4 V) |
| Encoders | 3 identical 0.1 in 2x4 header ports on one SPI bus (ENC1, ENC2 = MT6835, ENC3 = RLS Orbis); keyed/IDC plugs are chosen later |
| SSI encoders | 2 x 1x4 headers (SSI1, SSI2: 3V3, GND, CLK, DATA) for RLS RM08 encoders through an inline LDB02 line-driver board the owner fits near the Pico; one shared clock, one data line each, read by a PIO state machine |
| Triggers | Opto-isolated trigger in (3.3-24 V), open-collector trigger out with a jumper-selected pull-up |
| Soft stop | Normally-closed loop input (open = stop an excitation) |
| Bring-up | 2 GND test points (scope clip) |

Owner decisions already made (do not reopen without asking): through-hole only; servos run at 8.4 V straight from the Pololu; plain 0.1 in pin headers for every connector (the owner chooses keyed/IDC plugs later, and relies on keying instead of board-side reverse-polarity protection); the Pico, Pololu and BabyBuck are soldered straight to the board (no sockets); test points are plain pads; no fuse (the bench supply current limit protects); no SBUS pull-down; strain-gauge hardware on its own board with its own 3.3 V regulator; the footprints in `HastaDAQ.pretty` were checked against the real modules by the owner.

## 2. Where everything is

```
kicad/hastadaq/hastadaq.kicad_pro      open this in KiCad 10 (10.0.6 was used)
kicad/hastadaq/hastadaq.kicad_sch      the schematic (single sheet, A2). Net-label connectivity.
kicad/hastadaq/hastadaq.pdf / .png     pre-rendered copies (re-export after any change)
kicad/hastadaq/HastaDAQ.kicad_sym      project symbol library (generic block symbols)
kicad/hastadaq/HastaDAQ.pretty/        project footprints, SHARED with the gauge board (see section 6)
kicad/hastadaq/HastaDAQ.3dshapes/      3D model (IMU breakout only)
kicad/hastadaq/fp-lib-table, sym-lib-table   project library tables (nickname HastaDAQ)
kicad/gaugeboard/                      the strain-gauge board (own project; docs/PCB_BRIEF_GAUGE.md)
kicad/tools/schgen_common.py           shared generator helpers
kicad/tools/generate_hastadaq_sch.py   bootstrap generator that wrote this schematic
kicad/tools/generate_gauge_sch.py      bootstrap generator for the gauge board
kicad/tools/publish.py                 snapshots both schematics into a new folder kicad/releases/<date-time>[-label]/ to start PCB layout in (see section 10)
wiring/gauge-loom.yml                  WireViz diagram of the 4-wire loom between the boards (render with WireViz + Graphviz)
docs/PARTS_TO_SELECT.md                chosen parts with RS numbers, dimensions and the remaining open items
kicad/tools/generate_module_footprints.py   generator for the module footprints
docs/README.md                         project docs; HastaDAQ_v2/ is the firmware this PCB runs
```

**IMPORTANT, source of truth.** The schematic was generated by `generate_hastadaq_sch.py`, and that script reassigns reference designators and fresh random UUIDs on every run. **Once a `.kicad_pcb` exists, do not re-run the generator over the schematic**: it would break the schematic-to-board link. From the first "Update PCB from Schematic" on, edit the schematic in KiCad itself and treat the `.kicad_sch` as the source. (Before the PCB exists, schematic fixes are fine in the generator, but tell the owner.)

Tools on this machine: KiCad is installed per-user at `%LOCALAPPDATA%\Programs\KiCad\10.0\bin\` (not on PATH): `kicad-cli.exe` (ERC/DRC, netlist, Gerber, STEP, 3D render) and a bundled `python.exe` (has the `pcbnew` API, usable to script board creation/placement). No autorouter is bundled; hand-route, or use Freerouting via a Specctra DSN export/import. `kicad-cli` PDF exports carry a permissions lock; `pikepdf.open(path, password='')` then `.save(dst, encryption=False)` removes it.

Useful commands (run from the repo root):

```
kicad-cli sch erc --output erc.rpt --format report --severity-all kicad/hastadaq/hastadaq.kicad_sch
kicad-cli sch export netlist --format kicadsexpr --output hd.net kicad/hastadaq/hastadaq.kicad_sch
kicad-cli pcb drc --output drc.rpt --format report --severity-all kicad/hastadaq/hastadaq.kicad_pcb
kicad-cli pcb render --output top.png --side top kicad/hastadaq/hastadaq.kicad_pcb
```

Schematic status: **ERC 0 violations** (pins carry real electrical types, PWR_FLAGs are placed). The board file does not exist yet.

## 3. Power architecture

```
J8 (0.1 in 2x4 header, 12 V in, no fuse) -> +12V -+-> U2 Pololu D42V55F8 -> VSERVO (8.4 V) -> J7 servo header, C2 bulk
                                                                       +-> U3 BabyBuck 5V (EN left open) -> +5V -+-> encoder ports 5V pins, J2 loom pin 2 (gauge board), J10 SBUS IN V pin, C3 bulk
                                                                       |                                        +-> D1 Schottky -> +5V_VSYS -> Pico VSYS (pin 39)
                                                                       +-> C1 100 uF input bulk, J9 jumper (12 V pull-up option)
Pico 3V3(OUT) (pin 36) -> +3V3 -> IMU header J1, encoder ports 3V3 pins, pull-ups
```

* The gauge board gets **`+5V` only** (loom pin 2) and makes its own clean 3.3 V; the main board's 3V3 no longer feeds any ADC or bridge.
* The Pico's own 3V3 (Plus 2: AP7366 linear regulator from VSYS per Pimoroni's schematic; Pimoroni quotes 600 mA max) feeds the IMU, the encoders' 3V3 pins and the pull-ups. USB (VBUS) is left for programming only: with USB alone `+5V` is not live.
* Pico VSYS max is 5.5 V. The Schottky (D1, 1N5822 3 A) drops about 0.3-0.5 V; the Pico has its own on-board VBUS-to-VSYS diode so USB and the BabyBuck can coexist.
* The BabyBuck module already has 2 x 22 uF on its 5 V output and 2 x 4.7 uF on VIN; C3 is extra local bulk near the Pico and ports.
* Measured: the whole system drew about 1 A or less at 8.4 V. Rails sized for the worst case: the Pololu is limited to 5 A out (about 3.9 A in at 12 V).
* Current paths, rough IPC-2221 external-layer estimates for 1 oz copper at 10 C rise (verify with a calculator): 3 A needs about 1.4 mm, 5 A about 2.8 mm. Prefer pours for `+12V`, `VSERVO` and their returns.

## 4. Net names

`+12V`, `VSERVO`, `+5V`, `+5V_VSYS`, `+3V3`, `GND`, `SBUS`, `SBUS_IN`, `SBUS_IN_GPIO`, `SDA`, `SCL`, `SPI_SCK`, `SPI_MOSI`, `SPI_MISO`, `ENC1_CS`..`ENC3_CS`, `SSI_CLK`, `SSI1_DATA`, `SSI2_DATA`, `TRIG_IN`, `TRIG_IN_LED`, `TRIG_IN_GPIO`, `TRIG_OUT`, `TRIG_OUT_BASE`, `TRIG_OUT_GPIO`, `TRIG_PU`, `SOFTSTOP_CABLE`, `SOFTSTOP_IN`.

There is **one ground net**. See section 7 for how to treat it.

### Pico GPIO map (fixed by the schematic; the firmware depends on it)

| GPIO (header pin) | Net | Use |
|---|---|---|
| GP4 (6) / GP5 (7) | `SDA` / `SCL` | I2C0: the IMU header (J1) and the gauge-board loom (J2). No pull-ups on this board; the ADS122C04 breakouts (gauge board) and the IMU breakout have their own |
| GP10 (14) / GP11 (15) / GP12 (16) | `SPI_SCK` / `SPI_MOSI` / `SPI_MISO` | SPI1 shared by the three SPI encoder ports |
| GP13 (17) / GP9 (12) / GP8 (11) | `ENC1_CS` / `ENC2_CS` / `ENC3_CS` | encoder chip-selects, each with a 10 k pull-up to 3V3 (GP7 is now unused) |
| GP17 (22) | `SSI_CLK` | shared SSI clock out to both RM08 headers (J6, J11), driven by a PIO state machine; idles high |
| GP18 (24) / GP19 (25) | `SSI1_DATA` / `SSI2_DATA` | SSI data in from each RM08 (J6 / J11), each with a 10 k pull-up to 3V3; consecutive pins so one PIO `in pins,2` samples both on the same clock edge |
| GP14 (19) | `TRIG_IN_GPIO` | trigger in (opto output, 10 k pull-up, inverted) |
| GP15 (20) | `TRIG_OUT_GPIO` | trigger out (to the NPN base, inverted) |
| GP1 (2) | `SBUS_IN_GPIO` | SBUS from an RC receiver (J10) through 1 k, with a 5.1 V zener clamp (D4) and a 10 k pull-down (R14, leave unfitted at first, see section 9); UART0 RX. Pass-through firmware is not written yet. |
| GP16 (21) | `SOFTSTOP_IN` | soft stop (1 k series, 10 k pull-up, 5.1 V zener to GND) |
| GP20 (26) / GP21 (27) | `SBUS` (both) | UART1 TX and RX tied together on one net (firmware inverts the UART) |
| GP32-GP36 | (SP/CE connector, not on the header) | RM2 WiFi breakout, cabled off-board |

Do not change a GPIO assignment without telling the owner: it is a firmware change.

## 5. Connectors and pin maps

(Generated from the netlist on the day of writing. Pin numbers are the footprint pad numbers; 2-row headers number row-major: 1,2 across the first row, 3,4 the next, and so on.)

* **J8** (main supply cable, 0.1 in 2x4 header; **supply max 20 V**): 1=+12V, 2=GND, 3=TRIG_IN, 4=SOFTSTOP_CABLE, 5=GND (SOFTSTOP-), 6=TRIG_OUT, 7=GND, 8=+12V. Laid out so that even a 180-degree rotated plug puts supply on supply and ground on ground; the keyed shroud prevents it anyway. Two supply pins carry the system current.
* **J3-J5** (ENC1-ENC3, 0.1 in 2x4 headers, identical): 1=GND, 2=ENCn_CS, 3=SPI_SCK, 4=SPI_MOSI, 5=SPI_MISO, 6=+3V3, 7=+5V, 8=GND. MT6835 uses 3V3, RLS Orbis uses the 5V pin (4.5-5.5 V, 3.3 V logic). Keep these leads short. Intended use: ENC1 and ENC2 MT6835, ENC3 Orbis.
* **J6** (SSI1) and **J11** (SSI2), 0.1 in 1x4 headers, identical: 1=+3V3, 2=GND, 3=SSI_CLK, 4=SSIn_DATA (3.3 V single-ended). Each carries one RLS RM08 (SC output, 12-bit) through an inline LDB02 line-driver board that the owner places near the Pico; the board's RS422 side and the RM08's 3.3 V supply are the owner's wiring. The clock net is shared by both headers (one GPIO drives both). An SSI data output is always driven, so the two data lines must not be tied together or to `SPI_MISO`. Each DATA line has a 10 k pull-up (R4 for SSI1, R15 for SSI2) so an unplugged header reads all ones, which the firmware rejects as an invalid frame. Keep the clock and data leads short and away from the servo rail. The 3V3 pin feeds the LDB02 and RM08 (about 26 mA typical per encoder, more for the line driver): well inside the Pico Plus 2's 3V3 regulator.
* **J7** (SBUS, custom `HastaDAQ:PinHeader_3x06_P2.54mm_Vertical`): six servo plugs side by side; for servo k=1..6 the pins are 3k-2 = GND, 3k-1 = VSERVO, 3k = SBUS (the servo plug order, V in the middle).
* **J10** (SBUS IN, RC receiver, 1x3): 1=GND, 2=+5V, 3=SBUS_IN. Same plug order as the servos (GND, V, SIG). The receiver is powered from **`+5V`, not the 8.4 V servo rail**: the Futaba R3008SB manual gives 4.8 V to 7.4 V, so `VSERVO` would overstress it (check any other receiver's range, and never connect a second supply to the V pin). The signal passes a 1 k series resistor, a 5.1 V zener D4 to GND (clamps a receiver that outputs more than 5.1 V; its capacitance, about 100 pF, is harmless at SBUS's 100 kbaud) and a 10 k pull-down R14, which holds the line at the idle-low level of inverted SBUS when nothing is plugged in. **Leave R14 unfitted for the first trial and add it only if the idle level needs it**: the RP2350 errata (E9) say a pin with a weak pull-down (above about 8.2 k) can sit near 2 V when its input is enabled, so if R14 is fitted and the pin misbehaves use 4.7 k. The 1 k and 10 k divider gives GP1 3.0 V from a 3.3 V receiver.
* **J2** (gauge-board loom, 1x4 header): 1=GND, 2=+5V, 3=SDA, 4=SCL. Pin 2 is **5 V, not 3V3**: it is deliberately not Qwiic-compatible, so use a keyed plug and never connect a Qwiic cable or a bare Qwiic sensor to it. The matching header on the gauge board (J1) has the same order, so the loom is a straight 1:1 cable. Keep it short (boards sit side by side); SDA/SCL swing to the 3V3 set by the breakouts' pull-ups on the gauge board.
* **J1** (IMU, 1x4): 1=GND, 2=+3V3, 3=SDA, 4=SCL. Plain 1x4 0.1 in header (the custom `Qwiic_Breakout_1x4_Socket` footprint is still in the library but unused). This is the 3V3 version: do not mix it up with J2.
* **J9** (TRIG_OUT pull-up select, 1x5 in one row): 1=+3V3, 2=TRIG_PU, 3=+5V, 4=TRIG_PU, 5=+12V. A 2-pin shunt bridges only adjacent pins, so it can only ever join a rail to `TRIG_PU`, never two rails together (an earlier 2x3 header let a vertically placed shunt join 3V3 to 5V or 5V to 12V). Shunt 1-2 for 3V3, 2-3 or 3-4 for 5V, 4-5 for 12V; fit **one** shunt or none. **Label the voltage under each rail pin on the silkscreen**: the 12 V pin on a 3.3 V-limited receiver would damage it.
* Test points TP1-TP2 (GND), section 8.

The trigger lines can carry up to 24 V (external pull-up in the harness), so keep reasonable clearance between the trigger-in/out nets and the logic.

## 6. Footprints and modules

The owner checked these against the physical modules (1:1 print) on 2026-10-23. Pad numbers match the schematic symbol pin numbers. Origin is pad 1 in each, y positive downward. `HastaDAQ.pretty` is shared: the gauge board's library table points at this folder, so edits here also reach it.

| Part | Footprint | Source / key facts |
|---|---|---|
| U1 Pico Plus 2 | `Module:RaspberryPi_Pico_Common_THT` (stock) | 40 pads, 2.54 mm pitch, rows 17.78 mm apart; board 51 x 21 mm (Pimoroni mechanical diagram). Plus 2 has USB-C at one end; its SP/CE JST (8-pin, GP32-GP36) is reported on the **underside** and its Qw/ST and debug JST connectors on top: leave room below and above the module and keep the USB-C end clear of tall parts. |
| U2 Pololu | `HastaDAQ:Pololu_D42V55Fx` | Pololu dimension drawing 0J2180 + pinout photo. 25.4 mm square; 12 pads (1.02 mm holes) in a 2x6 grid; three 2.18 mm holes (2.2 mm in from three corners). Columns VOUT GND GND VIN VRP PG(inner)/EN(edge); odd pads inner row, even pads edge row. **6.1 mm tall** above the board (D42V55F8), 1.4 mm below. VRP, PG and EN are unused (EN has a 1 M pull-up to VIN on the module). |
| U3 BabyBuck | `HastaDAQ:SparkFun_BabyBuck_5V` | SparkFun Eagle file. 15.875 x 13.208 mm; one 1x4 header; pads bottom to top 5V GND VIN EN; no mounting holes. EN is left open (data sheet: floating EN auto-starts; the module's own divider sets about 6.2 V start-up). |
| J1 IMU header | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` | plain 1x4 header for four wires or a Qwiic breakout (the earlier custom Qwiic footprint with its STEP model is still in `HastaDAQ.pretty` but unused) |
| U4 FOD817A | `Package_DIP:DIP-4_W7.62mm` | RS 761-4439 (onsemi FOD817A, 4-pin DIP, CTR 80-160 %): pin-compatible with PC817 |
| Q1 2N3904 | `Package_TO_SOT_THT:TO-92_Inline` | pin 1 E, 2 B, 3 C (Fairchild/onsemi Rev 1.1.0 data sheet). Orient the flat face to the footprint outline. |
| J6, J11 SSI1/SSI2 | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` | plain 1x4 header: 3V3, GND, CLK, DATA |
| J3-J5, J8 | `Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical` | plain 0.1 in 2x4 header for now; pad numbering is identical to the keyed IDC box header that may replace it later (the owner chooses the keyed plug type) |

The generators can re-create the module footprints (`py kicad/tools/generate_module_footprints.py`); the 3x6 header footprint is written by the main schematic generator. Edits made by hand in the KiCad footprint editor are fine, but then do not re-run the footprint generator. (The ADS122C04 breakout footprint in the same library is used only by the gauge board.)

### Parts list (from the schematic)

| Ref | Value / description | Footprint |
|---|---|---|
| C1 | 100uF 25V input bulk (Panasonic ECA1EM101, 6.3 x 11.2 mm) | `Capacitor_THT:CP_Radial_D6.3mm_P2.50mm` |
| C2 | 470uF 16V servo bulk (Panasonic EEUFR1C471, 8 x 11.5 mm) | `Capacitor_THT:CP_Radial_D8.0mm_P3.50mm` |
| C3 | 100uF 10V 5V bulk (RS PRO LHK, 5 x 7 mm) | `Capacitor_THT:CP_Radial_D5.0mm_P2.00mm` |
| D1 | Schottky (e.g. 1N5822, 3A) | `Diode_THT:D_DO-201AD_P15.24mm_Horizontal` |
| D2 | 5.1V zener (BZX55C5V1) soft-stop clamp | `Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal` |
| D3 | 1N4148 (LED reverse protect) | `Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal` |
| D4 | 5.1V zener (BZX55C5V1) SBUS IN clamp | `Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal` |
| J1 | IMU via Qwiic breakout (The Pi Hut 106676) | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| J2 | Gauge-board loom (1x4): GND, +5V, SDA, SCL | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| J3 | ENC1 SPI port: MT6835 (pitch) | `Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical` |
| J4 | ENC2 SPI port: MT6835 | `Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical` |
| J5 | ENC3 SPI port: RLS Orbis (or MT6835) | `Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical` |
| J6 | SSI1: RM08 encoder (3V3, GND, CLK, DATA) | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| J7 | SBUS servo header 3x6 (6 plugs: GND, V, SIG) | `HastaDAQ:PinHeader_3x06_P2.54mm_Vertical` |
| J8 | Main supply cable (2x4): VSUPPLY, VGND, TRIG, SOFTSTOP | `Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical` |
| J9 | TRIG_OUT pull-up sel. (1x5) | `Connector_PinHeader_2.54mm:PinHeader_1x05_P2.54mm_Vertical` |
| J10 | SBUS IN (RC receiver): GND, V, SIG | `Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical` |
| J11 | SSI2: RM08 encoder (3V3, GND, CLK, DATA) | `Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical` |
| Q1 | 2N3904 NPN (TO-92, pin 1 E, 2 B, 3 C) | `Package_TO_SOT_THT:TO-92_Inline` |
| R1-R3 | 10k (ENCn_CS pull-ups to 3V3) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R4 | 10k (SSI1_DATA pull-up to 3V3; this was the fourth ENC chip-select pull-up before ENC4 was removed) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R5 | 1k (soft-stop series) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R6 | 10k (soft-stop pull-up) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R7 | 10k pull-down | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R8 | 1k 1W | `Resistor_THT:R_Axial_DIN0411_L9.9mm_D3.6mm_P12.70mm_Horizontal` |
| R9 | 10k pull-up | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R10 | 2.2k (base) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R11 | 10k (base-emitter) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R12 | 1.5k pull-up | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R13 | 1k series | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R14 | 10k pull-down (SBUS IN; leave unfitted on the first trial) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| R15 | 10k (SSI2_DATA pull-up to 3V3) | `Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal` |
| TP1 | TP | `TestPoint:TestPoint_Pad_D2.0mm` |
| TP2 | TP | `TestPoint:TestPoint_Pad_D2.0mm` |
| U1 | Pimoroni Pico Plus 2 (header pins) | `Module:RaspberryPi_Pico_Common_THT` |
| U2 | Pololu D42V55F8 8.4V 5A buck (servo rail) | `HastaDAQ:Pololu_D42V55Fx` |
| U3 | SparkFun BabyBuck 5V (AP63357) (Pico VSYS, Orbis, gauge board) | `HastaDAQ:SparkFun_BabyBuck_5V` |
| U4 | FOD817A opto (TRIG_IN) | `Package_DIP:DIP-4_W7.62mm` |

Values marked "(e.g. ...)" are suggestions, not fixed parts. All parts are through-hole. R1-R3 are the three encoder chip-select pull-ups, R4 and R15 the two SSI data pull-ups; the netlist lists them as separate parts with identical values.

## 7. Layout guidance

**Ground.** Use **one solid ground plane**, no split planes and no separate analog ground net: split planes degrade the SPI and I2C return paths, and there is no sensitive analog circuit on this board any more (the ADCs, bridge excitation and reference are on the gauge board, which has its own regulator). A 2-layer board (ground pour on the bottom) is enough; 4 layers is optional. Separate noisy from quiet **by placement and routing**:

1. Supply connector J8, Pololu, the SBUS header J7 and SBUS IN J10 at one end. Run the servo current (`VSERVO` and its return) along the board edge between them, so it never passes under the Pico or the loom/IMU connectors.
2. Put the loom header J2 and the IMU header J1 at the Pico end, away from the Pololu and the servo traces: SDA/SCL leave the board here toward the gauge board. Keep the `+5V` pin of J2 fed from the BabyBuck/C3 directly (a short wide trace); the gauge board filters it again, but avoid routing it past the Pololu inductor.
3. Let the grounds meet near the supply connector. Place the two `GND` test points near the supply and near the Pico.
4. Orientation: the boards sit side by side, so place J2 on the edge facing the gauge board.

**Other.**

* SPI (`SPI_SCK/MOSI/MISO` and the three CS), the SSI clock and data (`SSI_CLK`, `SSI1_DATA`, `SSI2_DATA`) and I2C: short, over solid ground, away from the servo rail. The encoder ports are the only external SPI/SSI cables. GP17-GP19 (the SSI pins) are on the **lower right** of the Pico with USB-C at the top, so place the two SSI headers J6 and J11 toward the lower right, not with the SPI encoder headers.
* Wide traces/pours for `+12V`, `VSERVO` and their returns (section 3 numbers). Give the Pololu pads (VOUT/GND/VIN duplicated on both rows) copper that uses every pad.
* Keep the opto/trigger/soft-stop parts together near J8 and away from the Pico end.
* Silkscreen: pin 1 on every connector, function names on J8 (with **"MAX 20V IN"** beside the supply pins), J3-J5, J6 and J11 (3V3, GND, CLK, DATA), J7 (GND, V, SIG per plug), J2 (**"+5V, NOT 3V3"** on pin 2, keyed plug; a reversed plug puts +5V on SDA and SCL on GND, an accepted risk, so also print an arrow or a pin 1 marker beside the header), J9 (voltage at each rail pin), J10 (GND, V=5V, SIG), the electrolytic polarities (C1, C2, C3), and "BabyBuck EN open".
**Mechanical guidelines for both boards (owner, 2026-10-26; guidelines, not rules).**

* **Mounting:** four M3 holes, one in each corner (3.2 mm non-plated holes, centres about 4 mm in from each edge, copper and parts kept about 6.5 mm clear for the screw head). M3 is the usual default on general PCBs; M2.5 (2.7 mm holes) is the Raspberry Pi convention and only worth using if the enclosure standoffs are already M2.5. Use M3 on both boards so one set of hardware fits both. Round the corners (about 2-3 mm radius).
* **Everything on the top face.** All components and every connector go on the top; nothing on the bottom except solder joints, copper and silkscreen, so the board sits flat on standoffs or a plate. Use standoffs taller than the longest solder-side lead (the Pololu's pins stand 1.4 mm proud), and trim the leads flush.
* **Connectors all face the same way:** vertical 0.1 in headers on the top face, all mated from above, grouped near one end of the board so every cable leaves the same side. (Right-angle headers pointing off an edge are the alternative; that is a footprint swap only, say so if you want it.)

**Main board placement (owner's suggestion): portrait, USB-C pointing off the top edge.**

```
              USB-C off the top edge
        +---------------------------------+
        |  J2 loom   [  Pico Plus 2  ]  BabyBuck (near VSYS)
        |  J1 IMU    [  51 x 21 mm   ]  Pololu  (alongside the Pico)
        |  (left edge, near GP4/GP5)       |
        |                                  |
        | ENC1-3 (bottom left)  J8 supply (bottom centre/right)  (SSI J6/J11 near the Pico's lower right pins)
        |                       J10 + J7 SBUS (bottom right)
        +---------------------------------+
```

* **Group by current, not by voltage.** 12 V, 8.4 V and 5 V are all low-voltage; what matters is current and switching noise. Keep the high-current path J8 -> Pololu -> J7 (about 4 A in at 12 V, up to 5 A out at 8.4 V) short and in one region (bottom right, with the Pololu beside the Pico). Keep the logic, the SPI and I2C traces and the encoder connectors on the other side (left), away from the Pololu's inductor and the BabyBuck.
* **Supply at the bottom rather than the top.** Putting J8 at the top right would split the cables between both ends and place a 12 V connector beside the USB-C. The Pico's pins also point the other way: with USB-C at the top, pin 1 is top left, so the SPI, chip selects and triggers (pins 10-17, 19, 20) are on the **lower left**, the SBUS pins GP20/21 (26, 27) and soft stop GP16 (21) are on the **lower right**, and I2C GP4/GP5 (pins 6, 7) are **upper left**. So: encoders bottom left, J8 and the trigger and soft-stop parts bottom centre, J7 and J10 bottom right, and the loom J2 and IMU J1 on the left edge near the top (the gauge board sits to the left, J2 on the edge facing it).
* **Exceptions:** GP1 (SBUS IN, pin 2) is at the top left, so J10's signal is the longest signal run; it is slow (100 kbaud), 1 k-limited and clamped, so that is fine, but keep it away from the Pololu and the servo traces. The `+5V` has to reach the Pico VSYS (top right, pin 39), the encoder ports (bottom left) and J2, so put the BabyBuck on the right above the Pololu and route `+5V` as a wide trace or pour (at least 1 mm).
* The module heights and positions matter more than the exact sketch: the Pololu is 25.4 mm square and 6.1 mm tall, and the Pico Plus 2's SP/CE JST sits on its underside, so keep the board under that part free of parts and copper (a cut-out or keepout) and check it on the 1:1 print.
* Width target: stay inside 100 x 100 mm (PCBWay's cheapest tier). The three encoder headers, the two SSI headers, J8, J7 (15.2 mm wide), J10 and J2 do not fit along one 70 mm bottom edge: use the bottom edge and the lower parts of the side edges, or two rows near the bottom.
* Still not given: the exact board outline and the enclosure. Allow for the Pico's USB-C overhang, its underside SP/CE JST and the Pololu's 6.1 mm height.

## 8. Test points

TP1 and TP2 (`TestPoint:TestPoint_Pad_D2.0mm`) are two plain 2.0 mm `GND` pads (SMD-style copper, no hole) for a scope ground clip: place one near the supply connector and one near the Pico. There are deliberately **no** voltage or signal test points: the owner probes rails and signals at component leads and header pins (C1, C2 and C3 for `+12V`, `VSERVO` and `+5V`; D1 for `+5V` and `+5V_VSYS`; Pico pins 36 and 39; the pins of the unmated headers). Keep those leads and pads accessible from the top side (do not bury them under a module), and remember that a mated plug covers the pins on J8 and the encoder ports.

## 9. Known unverified items (hardware not yet run)

* **R14 (SBUS IN pull-down):** leave unfitted for the first trial. If the idle level of `SBUS_IN_GPIO` floats or reads wrongly without a receiver, add it; because of RP2350 erratum E9 use 4.7 k rather than 10 k if the pin then sticks near 2 V. (The pull-ups to 3V3 elsewhere, R1-R4, R6, R9, are not affected by E9.)

* The firmware (`HastaDAQ_v2`) compiles but has **not run on this board**: Orbis SPI mode (inferred as mode 1), the soft stop, trigger polarity both ways, and a short high level on `TRIG_OUT` at power-up (the open-collector output floats until firmware starts).
* ADS #2's I2C address is expected to be 0x41 with its ADDR0 jumper bridged (Adafruit's schematic: ADDR pins pulled to GND, jumpers tie them to VCC); not yet confirmed on hardware (the firmware scans at boot).
* BabyBuck EN: resolved from the AP63357 data sheet (DS41949): EN may be left floating (internal 1.5 uA pull-up) or tied to VIN (35 V abs max). With EN open, SparkFun's on-board divider sets start-up at about 6.2 V in and shutdown at about 5.7 V, so a supply sagging below about 5.7 V turns the 5 V rail off.
* Two SPI devices sharing MISO: both data sheets say high-Z when deselected; not measured.
* The FOD817A opto at a 3.3 V trigger input (about 2 mA through the 1 k) is the weakest case; the 3V3 jumper position on `TRIG_OUT` is for 3.3 V-limited receivers.
* The IMU breakout's vertical position (assumed 8.5 mm socket) is a visual aid only.
* I2C over the loom: untested. It is short by design (boards side by side), and the only pull-ups are on the breakouts (the Adafruit ADS122C04 board has 10 k on each of SDA and SCL, so two of them give 5 k in parallel; the IMU breakout adds its own). If the loom is lengthened, check the edges and consider a stronger pull-up.

Treat the first spin as a **prototype**: keep the jumpers and test points accessible.

## 10. Suggested workflow

0. **Publish first:** `py kicad/tools/publish.py --label rev-a` (add `--regenerate` to re-run the generators) checks that ERC is clean, then copies both projects, the libraries, PDFs, netlists and these briefs into a new folder `kicad/releases/<date-time>-rev-a/` with a `PUBLISHED.md` (git commit, ERC). Do the layout **in that folder**, not in `kicad/hastadaq`. Releases are never overwritten. If the schematic later has to change substantially, change the generator, publish a new folder and start layout again there; for a small fix after layout has begun, edit the schematic in KiCad inside the release.
1. Open `<release>/hastadaq/hastadaq.kicad_pro` (or `kicad/hastadaq/` if you are not using a release). Run ERC (expect 0 violations). Create `hastadaq.kicad_pcb` in the same folder (File > New Board, or script it with the bundled Python) and use **Tools > Update PCB from Schematic**.
2. Board setup: 2 copper layers, 1.6 mm, 1 oz; set net classes (power: 12 V/8.4 V/ground wide; signal; trigger lines with extra clearance) and fab limits to your manufacturer's capabilities (PCBWay, see section 0; through-hole drills of 1.0 mm for headers, 1.0-1.1 mm for modules).
3. Draw the board outline and mounting holes (ask the owner), then place connectors first (edges), then the modules following section 7, then discretes.
4. Route power and ground first, then SPI/I2C/triggers. Pour ground on both layers, stitch with vias.
5. Run DRC, fix everything, check clearance on 12 V and 24 V-capable nets, then export Gerbers and a drill file, plus a STEP for an enclosure check. Re-export `hastadaq.pdf/.png` only if the schematic changed.
6. Before sending: have the owner print the PCB 1:1 and hold the modules and connectors against it.
7. Do the gauge board separately (`docs/PCB_BRIEF_GAUGE.md`); check that the two J2/J1 headers are in the same pin order and sit on facing edges.

Report any schematic problem to the owner rather than silently working around it. Anything that needs a schematic change after layout starts is made in KiCad (not the generator) and annotated so the owner can mirror it in the docs.
