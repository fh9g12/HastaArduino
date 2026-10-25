"""Bootstrap generator for kicad/hastadaq/hastadaq.kicad_sch.

Currently the source of truth for the schematic: edit this script and re-run it
(it also writes HastaDAQ.kicad_sym, HastaDAQ.pretty and the lib tables). If you
start editing the .kicad_sch in KiCad instead, stop re-running this script, as it
overwrites those edits.

    py kicad/tools/generate_hastadaq_sch.py

Connectivity is by local net labels (no long wires) so the sheet stays
readable; only the completion-resistor divider is drawn with real wires.
Pins that are wired are electrically "passive"; intentionally unused pins are
"no_connect" so ERC stays quiet. Replace the generic blocks with real
symbols/footprints when moving to a PCB.

Pin data sources: Raspberry Pi Pico 2 W datasheet fig. 2 (the Pimoroni Pico
Plus 2 keeps the same 40-pin header; its Qwiic port is on GP4/GP5; SP/CE pins
from Pimoroni's Pico Plus 2 pinout diagram),
Adafruit ADS122C04 guide "Pinouts" page (labels VIN/Ref+/GND/Ref-/SCL/SDA/
DRDY/!RST/A0-A3; physical order isn't published, so symbol order is logical).
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import schgen_common as sg
from schgen_common import *  # noqa: F401,F403  (helpers: block, header, vertical_part, text, ...)

OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "hastadaq"
sg.init("hastadaq", OUT_DIR, "HastaDAQ", paper="A2")

# ----------------------------------------------------------------------- main
define_resistor()
define_fuse()
define_cap()
define_cap_polarized()
define_diode()
define_zener()
define_testpoint()
define_pwrflag()

# Pimoroni Pico Plus 2 -- all 40 header pins (Pico 2 W datasheet fig. 2; same header)
pico_left = [
    (1, "GP0 UART0-TX", None), (2, "GP1 UART0-RX", "SBUS_IN_GPIO"), (3, "GND", "GND"),
    (4, "GP2", None), (5, "GP3", None),
    (6, "GP4 I2C0-SDA", "SDA"), (7, "GP5 I2C0-SCL", "SCL"), (8, "GND", "GND"),
    (9, "GP6", None), (10, "GP7", "ENC4_CS"), (11, "GP8", "ENC3_CS"), (12, "GP9", "ENC2_CS"), (13, "GND", "GND"),
    (14, "GP10 SPI1-SCK", "SPI_SCK"), (15, "GP11 SPI1-TX", "SPI_MOSI"),
    (16, "GP12 SPI1-RX", "SPI_MISO"), (17, "GP13 SPI1-CSn", "ENC1_CS"), (18, "GND", "GND"),
    (19, "GP14", "TRIG_IN_GPIO"), (20, "GP15", "TRIG_OUT_GPIO"),
]
pico_right = [
    (40, "VBUS", None), (39, "VSYS", "+5V_VSYS"), (38, "GND", "GND"), (37, "3V3_EN", None),
    (36, "3V3(OUT)", "+3V3"), (35, "ADC_VREF", None), (34, "GP28", None), (33, "AGND", "GND"),
    (32, "GP27", None), (31, "GP26", None), (30, "RUN", None), (29, "GP22", None),
    (28, "GND", "GND"), (27, "GP21 UART1-RX", "SBUS"), (26, "GP20 UART1-TX", "SBUS"),
    (25, "GP19", None), (24, "GP18", None), (23, "GND", "GND"), (22, "GP17", None), (21, "GP16", "SOFTSTOP_IN"),
]
def _pico_t(t):
    num, name, net = t
    if net is None:
        return t
    if name in ("GND", "AGND", "VSYS"):
        return (num, name, net, "power_in")
    if name == "3V3(OUT)":
        return (num, name, net, "power_out")
    if name.startswith("GP"):
        return (num, name, net, "bidirectional")
    return t


pico_left = [_pico_t(t) for t in pico_left]
pico_right = [_pico_t(t) for t in pico_right]
block("PicoPlus2", "Pimoroni Pico Plus 2 (header pins)", 70, 140,
      pico_left, pico_right, width=60.96,
      footprint="Module:RaspberryPi_Pico_Common_THT")

header("IMU via Qwiic breakout (The Pi Hut 106676)", 185, 45,
       [("GND", "GND"), ("3V3", "+3V3"), ("SDA", "SDA"), ("SCL", "SCL")],
       footprint="HastaDAQ:Qwiic_Breakout_1x4_Socket")


# The strain-gauge hardware (2 x ADS122C04, half-bridge headers, completion resistors, its own 3.3 V regulator and
# filtering) lives on a SEPARATE board, kicad/gaugeboard/. It connects with a 4-wire I2C loom: GND, +5V, SDA, SCL
# (0.1in headers on both boards; use KEYED plugs). The 5V pin is NOT 3V3: do not plug a Qwiic device into it.
header("GAUGE BOARD LOOM (J_I2C): GND, +5V, SDA, SCL", 185, 115,
       [("GND", "GND"), ("5V", "+5V"), ("SDA", "SDA"), ("SCL", "SCL")])
text("Strain-gauge board: 4-wire I2C loom. Pin 2 is +5V, NOT 3V3 -- use a keyed plug,\n"
     "never a Qwiic cable. Pull-ups live on the ADS122C04 breakouts on that board.", 150, 140)

# encoders: three 2x4 0.1in headers on one SPI bus, each with its own CS.
# Pins 1..8 in order: GND, CS, SCK, MOSI, MISO, 3V3, 5V, GND. 3V3 powers an MT6835,
# 5V powers an RLS Orbis (3.3 V logic). Pull-ups keep unselected CS lines high at boot.
# keyed (polarised) shrouded 0.1in IDC box header: cannot be mated rotated 180 deg
FP_HDR_2X4 = "Connector_IDC:IDC-Header_2x04_P2.54mm_Vertical"


def enc_header(title, y, cs):
    pins = [("GND", "GND"), ("CS", cs), ("SCK", "SPI_SCK"), ("MOSI", "SPI_MOSI"),
            ("MISO", "SPI_MISO"), ("3V3", "+3V3"), ("5V", "+5V"), ("GND", "GND")]
    names = "".join(c if c.isalnum() else "p" for c in "_".join(nm for nm, _ in pins))
    block(f"Header2x04_{names}", title, 60, y,
          left=[(i + 1, name, net) for i, (name, net) in enumerate(pins)], right=[],
          ref_prefix="J", width=15.24, footprint=FP_HDR_2X4)


enc_header("ENC1 SPI port: MT6835 (pitch) / Orbis", 190, "ENC1_CS")
enc_header("ENC2 SPI port: MT6835 / Orbis", 222, "ENC2_CS")
enc_header("ENC3 SPI port: MT6835 / Orbis", 254, "ENC3_CS")
enc_header("ENC4 SPI port: generic SPI device", 286, "ENC4_CS")
for k, cs in enumerate(("ENC1_CS", "ENC2_CS", "ENC3_CS", "ENC4_CS")):
    px = snap(100 + k * 12)
    r_top, r_bot = resistor(px, snap(262), "10k")
    stub_label("+3V3", px, r_top[1], "up")
    stub_label(cs, px, r_bot[1], "down")
text("CS pull-ups (10k)", 96, 249)

# The RM2 WiFi breakout plugs into the Pico Plus 2 SP/CE connector (GP32-GP36) by cable; it is not on this PCB.


# power: 12 V in -> fuse -> +12V -> two bucks: 12->8.4 V (VSERVO: servos) and 12->5 V (+5V: Pico, Orbis)
# Pololu D42V55F8 module (fixed 8.4 V, 5 A, 8.4-60 V in), 2x6 pads on 2.54 mm, viewed from the top
# with the pads at the bottom. Rows as read off the module:
#   far row  : VOUT GND GND VIN VRP PG
#   near row : VOUT GND GND VIN VRP EN
# Duplicated VOUT/GND/VIN pads are all wired for current. EN is pulled up to VIN on the module, so
# it is left open; PG (open-drain) and VRP are unused. Footprint: a 2x06 header is used so that
# module column i maps to header row i (far row = odd pins, near row = even pins). Add the three
# M2 mounting holes (2.18 mm, 2.2 mm in from the corners) on the PCB, see Pololu's dimension drawing.
POL_FAR = [("VOUT", "VSERVO"), ("GND", "GND"), ("GND", "GND"), ("VIN", "+12V"), ("VRP", None), ("PG", None)]
POL_NEAR = [("VOUT", "VSERVO"), ("GND", "GND"), ("GND", "GND"), ("VIN", "+12V"), ("VRP", None), ("EN", None)]
def _pol_type(num, name):
    if name in ("VIN", "GND"):
        return "power_in"
    if name == "VOUT":
        return "power_out" if num == 1 else "passive"  # one driver per net; the other VOUT pad is a duplicate
    return "passive"


block("D42V55F8", "Pololu D42V55F8 8.4V 5A buck (servo rail)", 140, 300,
      left=[(2 * k + 1, nm, net, _pol_type(2 * k + 1, nm)) for k, (nm, net) in enumerate(POL_FAR)],
      right=[(2 * k + 2, nm, net, _pol_type(2 * k + 2, nm)) for k, (nm, net) in enumerate(POL_NEAR)],
      ref_prefix="U", width=30.48,
      footprint="HastaDAQ:Pololu_D42V55Fx")
# SparkFun BabyBuck 5V (AP63357, 6-32 V in, ~3 A): 4 pins on 0.1" pitch, order along the header
# as read off the module: 5V GND VIN EN. EN is LEFT OPEN: SparkFun's own schematic has an on-board divider
# (93.1k VIN->EN, 22k EN->GND, ~2.3 V at 12 V) that enables the converter, and the AP63357 EN pin limit could
# not be found, so it is not tied to 12 V. The module has 2x22uF on 5V and 2x4.7uF on VIN.
block("BabyBuck_5V", "SparkFun BabyBuck 5V (AP63357) (Pico VSYS, Orbis)", 140, 340,
      left=[(3, "VIN", "+12V", "power_in"), (2, "GND", "GND", "power_in"), (4, "EN", None)],
      right=[(1, "VOUT 5V", "+5V", "power_out")],
      ref_prefix="U", width=30.48, footprint="HastaDAQ:SparkFun_BabyBuck_5V")
vertical_part("Fuse", "F", "Fuse T3.15A 5x20mm time-delay", 250, 300, "+12V_IN", "+12V",
              "Fuse:Fuseholder_Clip-5x20mm_Keystone_3517_Inline_P23.11x6.76mm_D1.70mm_Horizontal")
vertical_part("C_Polarized", "C", "100uF input bulk (>=25V)", 285, 300, "+12V", "GND",
              "Capacitor_THT:CP_Radial_D8.0mm_P3.50mm")
vertical_part("C_Polarized", "C", "470-1000uF servo bulk (>=16V)", 285, 330, "VSERVO", "GND",
              "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm")
ref_d = next_ref("D")
dx, dy = snap(210), snap(340)
instance("HastaDAQ:D_Schottky", ref_d, "Schottky (e.g. 1N5822, 3A)", dx, dy, ["A", "K"],
         (dx - 5, dy - 5.08), (dx - 5, dy - 2.54), "Diode_THT:D_DO-201AD_P15.24mm_Horizontal")
stub_label("+5V", dx - 3.81, dy, "left")
stub_label("+5V_VSYS", dx + 3.81, dy, "right")
# local bulk on +5V near the Pico / encoder ports (the BabyBuck only has 2x22uF ceramic at the converter)
vertical_part("C_Polarized", "C", "100uF 5V bulk (>=10V)", 250, 345, "+5V", "GND",
              "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm")

# SBUS out: one 3x6 servo header, 6 servo plugs side by side. Servo k = pins 3k-2 (GND), 3k-1 (V), 3k (SIG),
# the servos' plug order with V in the middle; V = VSERVO, SIG = SBUS (all six in parallel), GND. Footprint is the project's own HastaDAQ:PinHeader_3x06
# (KiCad has no 3x6 header): 6 columns on 2.54 mm, rows GND / V / SIG, pad 1 square.
FP_SBUS = "HastaDAQ:PinHeader_3x06_P2.54mm_Vertical"
sbus_pins = []
for k in range(6):
    sbus_pins += [(3 * k + 1, f"S{k + 1} GND", "GND"), (3 * k + 2, f"S{k + 1} V", "VSERVO"),
                  (3 * k + 3, f"S{k + 1} SIG", "SBUS")]
block("Header3x06_SBUS", "SBUS servo header 3x6 (6 plugs: GND, V, SIG)", 380, 75,
      left=sbus_pins, right=[], ref_prefix="J", width=15.24, footprint=FP_SBUS)

# Main supply cable: 2x4 0.1in header, pins 1..8 row-major (1,2 / 3,4 / 5,6 / 7,8). Functions are placed
# so a connector plugged in rotated 180 deg (pin i <-> 9-i) still gets supply on supply and ground on
# ground; use a keyed/shrouded header to stop the mirrored mis-plug. SOFTSTOP+ / SOFTSTOP- are the two
# ends of a normally-closed loop at the far end: SOFTSTOP- is board GND, SOFTSTOP+ goes through 1k to a
# Pico GPIO that is pulled up to 3V3. Loop intact = low = run; loop broken (cable pulled, switch open) =
# high = stop the manoeuvre in firmware.
pw_pins = [("VSUPPLY", "+12V_IN"), ("VGND", "GND"), ("TRIG_IN", "TRIG_IN"), ("SOFTSTOP+", "SOFTSTOP_CABLE"),
           ("SOFTSTOP-", "GND"), ("TRIG_OUT", "TRIG_OUT"), ("VGND", "GND"), ("VSUPPLY", "+12V_IN")]
pw_names = "".join(c if c.isalnum() else "p" for c in "_".join(nm for nm, _ in pw_pins))
block(f"Header2x04_{pw_names}", "Main supply cable (2x4): VSUPPLY, VGND, TRIG, SOFTSTOP", 380, 215,
      left=[(i + 1, name, net) for i, (name, net) in enumerate(pw_pins)], right=[],
      ref_prefix="J", width=15.24, footprint=FP_HDR_2X4)
r_fp = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
vertical_part("R", "R", "1k (soft-stop series)", 330, 260, "SOFTSTOP_CABLE", "SOFTSTOP_IN", r_fp)
vertical_part("R", "R", "10k (soft-stop pull-up)", 385, 260, "+3V3", "SOFTSTOP_IN", r_fp)
# protection: 5.1 V zener from the GPIO node to GND clamps a cable fault to 12 V above (and negative spikes below)
# the 5.5 V the RP2350 pin tolerates; the 1k series resistor limits the fault current to ~7 mA.
ref_z = next_ref("D")
zx, zy = snap(358), snap(296)
instance("HastaDAQ:D_Zener", ref_z, "5.1V zener (BZX55C5V1) soft-stop clamp", zx, zy, ["A", "K"],
         (zx - 5, zy - 5.08), (zx - 5, zy - 2.54), "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal")
stub_label("GND", zx - 3.81, zy, "left")
stub_label("SOFTSTOP_IN", zx + 3.81, zy, "right")

# Trigger I/O conditioning for 3.3 V .. 24 V equipment (all through hole).
# TRIG_IN : cable -> 1k/1W -> PC817 LED (1N4148 antiparallel, 10k pull-down on the cable side);
#           opto transistor pulls TRIG_IN_GPIO (GP14) low, 10k pull-up to 3V3. Inverted: active = low.
# TRIG_OUT: GP15 -> 2.2k -> 2N3904 base (10k base-emitter pull-down); collector = TRIG_OUT cable line. Open collector,
#           1.5k pull-up from TRIG_PU, which a 2x3 jumper header ties to 3V3, 5V or +12V (or leave
#           off if the receiver has its own pull-up). Inverted: GPIO high = line low.
FP_R = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
FP_R1W = "Resistor_THT:R_Axial_DIN0411_L9.9mm_D3.6mm_P12.70mm_Horizontal"

text("TRIGGER IN: any 3.3 V .. 24 V level, opto input", 455, 215)
vertical_part("R", "R", "10k pull-down", 435, 235, "TRIG_IN", "GND", FP_R)
vertical_part("R", "R", "1k 1W", 455, 235, "TRIG_IN", "TRIG_IN_LED", FP_R1W)
ref_d2 = next_ref("D")
d2x, d2y = snap(455), snap(260)
instance("HastaDAQ:D_Schottky", ref_d2, "1N4148 (LED reverse protect)", d2x, d2y, ["A", "K"],
         (d2x - 5, d2y - 5.08), (d2x - 5, d2y - 2.54), "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal")
stub_label("GND", d2x - 3.81, d2y, "left")
stub_label("TRIG_IN_LED", d2x + 3.81, d2y, "right")
block("PC817", "PC817 opto (TRIG_IN)", 495, 235,
      left=[(1, "A", "TRIG_IN_LED"), (2, "K", "GND")],
      right=[(4, "C", "TRIG_IN_GPIO"), (3, "E", "GND")],
      ref_prefix="U", width=20.32, footprint="Package_DIP:DIP-4_W7.62mm")
vertical_part("R", "R", "10k pull-up", 535, 235, "+3V3", "TRIG_IN_GPIO", FP_R)

text("TRIGGER OUT: open-collector NPN, pull-up rail chosen by jumper", 430, 285)
vertical_part("R", "R", "2.2k (base)", 435, 315, "TRIG_OUT_GPIO", "TRIG_OUT_BASE", FP_R)
vertical_part("R", "R", "10k (base-emitter)", 455, 315, "TRIG_OUT_BASE", "GND", FP_R)
block("2N3904", "2N3904 NPN (TO-92, pin 1 E, 2 B, 3 C)", 495, 315,
      left=[(2, "B", "TRIG_OUT_BASE")],
      right=[(3, "C", "TRIG_OUT"), (1, "E", "GND")],
      ref_prefix="Q", width=15.24, footprint="Package_TO_SOT_THT:TO-92_Inline")
vertical_part("R", "R", "1.5k pull-up", 535, 315, "TRIG_PU", "TRIG_OUT", FP_R)
pu_pins = [("3V3", "+3V3"), ("PU", "TRIG_PU"), ("5V", "+5V"), ("PU", "TRIG_PU"),
           ("12V", "+12V"), ("PU", "TRIG_PU")]
block("Header2x03_PU_SEL", "TRIG_OUT pull-up sel.", 570, 315,
      left=[(i + 1, nm, net) for i, (nm, net) in enumerate(pu_pins)], right=[],
      ref_prefix="J", width=15.24,
      footprint="Connector_PinHeader_2.54mm:PinHeader_2x03_P2.54mm_Vertical")
text("Jumper a row (3V3 / 5V / 12V) to pull TRIG_OUT up to that rail; remove it if the receiver has its own pull-up.\n"
     "Pull-up current: 3.3 V ~2 mA, 5 V ~3 mA, 12 V ~7 mA (enough for a 6.5 mA opto input such as MPS4200).\n"
     "24 V receivers: no jumper, add an external 24 V pull-up in the harness. 3V3 for eSync 2 high-Z ports (3.3 V max).", 430, 345)

# SBUS IN: an RC receiver's SBUS output (pass-through use). Same 3-pin plug order as the servos (GND, V, SIG).
# V is the servo rail (VSERVO, 8.4 V: check the receiver's maximum supply). The signal goes through 1k to GP1
# (UART0 RX; the SBUS output uses UART1 on GP20/21) with a 10k pull-down: that holds the line at the idle-low
# level of inverted SBUS when no receiver is plugged in, and with the 1k forms a divider that gives the pin 3.0 V
# from a 3.3 V receiver or 4.5 V from a 5 V one (RP2350 pins tolerate 5.5 V when powered).
header("SBUS IN (RC receiver): GND, V, SIG", 395, 150,
       [("GND", "GND"), ("V", "VSERVO"), ("SIG", "SBUS_IN")])
vertical_part("R", "R", "1k series", 425, 170, "SBUS_IN", "SBUS_IN_GPIO", r_fp)
vertical_part("R", "R", "10k pull-down", 445, 170, "SBUS_IN_GPIO", "GND", r_fp)
text("SBUS IN: RC-receiver pass-through (plug order GND, V, SIG). V = VSERVO 8.4 V --\n"
     "check the receiver's max supply. SIG -> 1k -> GP1 (UART0 RX), 10k to GND.", 338, 198)

# Test points (through-hole pads) for bring-up, and PWR_FLAGs on nets that are supplied through a passive
# part (cable connector, fuse, diode) so ERC's power-pin check has a source on them.
FP_TP = "TestPoint:TestPoint_THTPad_D2.0mm_Drill1.0mm"
TP_NETS = ["GND", "GND"]
box(436, 28, 572, 128)
text("TEST POINTS (2.0 mm through-hole pads): two GND pads for a scope clip (near the supply and near the Pico).\n"
     "Rails and signals are probed at component leads and header pins (fuse clips, C5/C6/C7, D1, Pico pins 36/39).", 438, 40)
for i, net in enumerate(TP_NETS):
    tx, ty = snap(444 + i * 15), snap(66)
    instance("HastaDAQ:TestPoint", next_ref("TP"), "TP", tx, ty, [1], (tx + 2, ty - 1), (tx + 2, ty + 2), FP_TP)
    stub_label(net, tx, ty - 2.54, "up")
text("PWR_FLAG: marks nets supplied through the supply connector (+12V_IN, GND), the fuse (+12V) and the Schottky (+5V_VSYS)", 438, 90)
for i, net in enumerate(["+12V_IN", "+12V", "GND", "+5V_VSYS"]):
    fx, fy = snap(444 + i * 22), snap(104)
    instance("HastaDAQ:PWR_FLAG", next_ref("#FLG"), "PWR_FLAG", fx, fy, [1], (fx + 2, fy - 3), (fx + 2, fy - 1), "", bom=False)
    stub_label(net, fx, fy, "down", 2.54)

text("HastaDAQ", 20, 20, 3.0, bold=True)
text("Net labels connect everything: same name = same net. +3V3 / GND are plain labels, not power symbols.", 20, 27)
text("Pimoroni Pico Plus 2 (+ RM2 on SP/CE): same 40-pin header as Pico 2 W. I2C0 = GP4/GP5 (header pins 6/7), to the IMU\n"
     "Qwiic-breakout header and to the 4-wire loom for the strain-gauge board. Crossed-out pins are intentionally unused.", 20, 36)
text("NOTES\n"
     "1. ONE common GND (Pico, sensors, servo PSU). SBUS needs a shared ground reference.\n"
     "   RM2 WiFi breakout (off-board, cabled to the Pico Plus 2 SP/CE connector): uses GP32-GP36 only, no overlap with I2C (GP4/5) or any other signal.\n"
     "2. Strain gauges: SEPARATE board (kicad/gaugeboard), reached by a 4-wire I2C loom (GND, +5V, SDA, SCL; 0.1in headers, keyed plugs).\n"
     "   That board makes its own clean 3.3 V from +5V and holds both ADS122C04s, the gauge headers and the filtering.\n"
     "   ADS #2 needs its address jumper bridged (resulting address unconfirmed; firmware scans at boot). I2C pull-ups come from the\n"
     "   ADS122C04 breakouts on the gauge board and from the IMU breakout.\n"
     "3. SBUS: GP20 (TX) and GP21 (RX) on one net (UART inverted in firmware). One 3x6 servo header (6 plugs of GND, V, SIG;\n"
     "   footprint HastaDAQ:PinHeader_3x06): V = VSERVO (8.4 V), SIG = SBUS (all six in parallel), GND.\n"
     "4. POWER: 12 V in -> fuse -> +12V rail -> (a) Pololu D42V55F8 = VSERVO 8.4 V (servos), (b) SparkFun BabyBuck 5V = +5V (Orbis,\n"
     "   gauge-board loom, Schottky -> Pico VSYS). VSYS max is 5.5 V. USB (VBUS) is left for programming; with USB only, +5V is not live.\n"
     "   BabyBuck EN is left open (its own divider enables it). 5V bulk: module has 2x22uF; 100uF added near the Pico/ports.\n"
     "5. Triggers: TRIG_IN accepts 3.3-24 V (opto), TRIG_OUT is open collector with a jumper-selected pull-up. Pin order: see each symbol.\n"
     "   Main supply cable (2x4, pins 1-8 row-major): 1,8 VSUPPLY (12 V) | 2,7 VGND | 3 TRIG_IN | 6 TRIG_OUT | 4 SOFTSTOP+ | 5 SOFTSTOP-.\n"
     "   SOFTSTOP+ -> 1k -> GP16 (10k pull-up to 3V3, 5.1 V zener to GND), SOFTSTOP- = GND: loop closed = run, broken = stop.\n"
     "   Keyed shrouded IDC box headers (cannot be mated rotated) are used for this connector and ENC1-4. Measured system current\n"
     "   was <= 1 A at 8.4 V, well inside ~3 A per 0.1in pin.\n"
     "6. Encoders: 4 x 2x4 headers (pins 1-8: GND, CS, SCK, MOSI, MISO, 3V3, 5V, GND) on one SPI1 bus; CS = GP13/GP9/GP8/GP7.\n"
     "   MT6835 uses 3V3 (3.3 V logic); RLS Orbis uses 5V with 3.3 V logic. Check MISO tri-states when CS is high.\n"
     "   The four ENC headers are a generic SPI port (SPI1: SCK GP10, MOSI GP11, MISO GP12, own CS each, 3V3 and 5V supply), so any 3.3 V\n"
     "   SPI device can be plugged in, not just encoders. Each device needs its own CS and an MISO that tri-states when CS is high.",
     20, 405)

sg.write_outputs("${KIPRJMOD}/HastaDAQ.pretty")

# custom footprint library (HastaDAQ.pretty) with the 3x6 servo header
pretty = OUT_DIR / "HastaDAQ.pretty"
pretty.mkdir(exist_ok=True)
pads = []
for col in range(6):
    for row in range(3):
        num = 3 * col + row + 1
        shape = "rect" if num == 1 else "circle"
        pads.append(f'  (pad "{num}" thru_hole {shape} (at {n(col * 2.54)} {n(row * 2.54)}) (size 1.7 1.7) '
                    f'(drill 1.0) (layers "*.Cu" "*.Mask"))')
x2, y2 = 5 * 2.54 + 1.27, 2 * 2.54 + 1.27
fpmod = (
    '(footprint "PinHeader_3x06_P2.54mm_Vertical"\n  (version 20240108)\n  (generator "pcbnew")\n'
    '  (generator_version "8.0")\n  (layer "F.Cu")\n'
    '  (descr "3x6 pin header, 2.54 mm pitch: 6 servo plugs side by side, rows GND / V / SIG")\n'
    '  (tags "servo header 3x6 2.54mm")\n'
    '  (property "Reference" "REF**" (at 6.35 -2.54 0) (layer "F.SilkS") (effects (font (size 1 1) (thickness 0.15))))\n'
    '  (property "Value" "PinHeader_3x06_P2.54mm_Vertical" (at 6.35 7.62 0) (layer "F.Fab") (effects (font (size 1 1) (thickness 0.15))))\n'
    '  (attr through_hole)\n'
    f'  (fp_rect (start -1.27 -1.27) (end {n(x2)} {n(y2)}) (stroke (width 0.12) (type default)) (fill none) (layer "F.SilkS"))\n'
    f'  (fp_rect (start -1.77 -1.77) (end {n(x2 + 0.5)} {n(y2 + 0.5)}) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd"))\n'
    + "\n".join(pads) + "\n)\n")
(pretty / "PinHeader_3x06_P2.54mm_Vertical.kicad_mod").write_text(fpmod, encoding="utf-8")
