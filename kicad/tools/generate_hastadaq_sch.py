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
import uuid

OUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "hastadaq"
PROJECT = "hastadaq"
ROOT_UUID = str(uuid.uuid4())

FONT = "(effects (font (size 1.27 1.27)))"
STUB = 5.08
FP_HDR = "Connector_PinHeader_2.54mm:PinHeader_1x{n:02d}_P2.54mm_Vertical"


def u():
    return str(uuid.uuid4())


def snap(v):
    return round(v / 2.54) * 2.54


def n(v):
    return f"{round(v, 3):g}"


def q(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


lib_symbols = []
items = []
ref_counters = {}
defined_blocks = {}


def next_ref(prefix):
    ref_counters[prefix] = ref_counters.get(prefix, 0) + 1
    return f"{prefix}{ref_counters[prefix]}"


# ---------------------------------------------------------------- lib symbols
def lib_prop(name, value, hide=True):
    hide_s = " (hide yes)" if hide else ""
    return (f'(property "{name}" "{q(value)}" (at 0 0 0) '
            f'(effects (font (size 1.27 1.27)){hide_s}))')


def pin_expr(num, name, x, y, ang, length, ptype="passive"):
    return (f'(pin {ptype} line (at {n(x)} {n(y)} {ang}) (length {n(length)}) '
            f'(name "{q(name)}" {FONT}) (number "{q(str(num))}" {FONT}))')


def define_block(libname, left, right, width):
    """left/right = [(pin_number, pin_name, net_or_None)]."""
    if libname in defined_blocks:
        return defined_blocks[libname]
    rows = max(len(left), len(right))
    top = (rows - 1) * 1.27 + 2.54
    defined_blocks[libname] = (rows, top, width)
    pins = []
    for side, lst, x, ang in (("L", left, -width / 2 - STUB, 0), ("R", right, width / 2 + STUB, 180)):
        for i, (num, name, net) in enumerate(lst):
            y = (rows - 1) * 1.27 - i * 2.54
            pins.append(pin_expr(num, name, x, y, ang, STUB, "passive" if net else "no_connect"))
    sym = (
        f'(symbol "{libname}" (pin_names (offset 1.016)) (exclude_from_sim no) '
        f'(in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "U", False)} {lib_prop("Value", libname, False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        f'(symbol "{libname}_0_1" (rectangle (start {n(-width / 2)} {n(top)}) '
        f'(end {n(width / 2)} {n(-top)}) (stroke (width 0.254) (type default)) '
        f'(fill (type background)))) '
        f'(symbol "{libname}_1_1" {" ".join(pins)}) (embedded_fonts no))'
    )
    lib_symbols.append(sym)
    return defined_blocks[libname]


def define_resistor():
    lib_symbols.append(
        '(symbol "R" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "R", False)} {lib_prop("Value", "R", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "R_0_1" (rectangle (start -1.016 -2.54) (end 1.016 2.54) '
        '(stroke (width 0.254) (type default)) (fill (type none)))) '
        '(symbol "R_1_1" '
        f'{pin_expr(1, "", 0, 3.81, 270, 1.27)} '
        f'{pin_expr(2, "", 0, -3.81, 90, 1.27)}) (embedded_fonts no))')


def define_fuse():
    lib_symbols.append(
        '(symbol "Fuse" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "F", False)} {lib_prop("Value", "Fuse", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "Fuse_0_1" (rectangle (start -1.016 -2.54) (end 1.016 2.54) '
        '(stroke (width 0.254) (type default)) (fill (type none))) '
        '(polyline (pts (xy 0 2.54) (xy 0 -2.54)) (stroke (width 0) (type default)) (fill (type none)))) '
        '(symbol "Fuse_1_1" '
        f'{pin_expr(1, "", 0, 3.81, 270, 1.27)} '
        f'{pin_expr(2, "", 0, -3.81, 90, 1.27)}) (embedded_fonts no))')


def define_cap():
    lib_symbols.append(
        '(symbol "C" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "C", False)} {lib_prop("Value", "C", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "C_0_1" '
        '(polyline (pts (xy -2.032 0.762) (xy 2.032 0.762)) (stroke (width 0.508) (type default)) (fill (type none))) '
        '(polyline (pts (xy -2.032 -0.762) (xy 2.032 -0.762)) (stroke (width 0.508) (type default)) (fill (type none)))) '
        '(symbol "C_1_1" '
        f'{pin_expr(1, "", 0, 3.81, 270, 3.048)} '
        f'{pin_expr(2, "", 0, -3.81, 90, 3.048)}) (embedded_fonts no))')


def define_cap_polarized():
    lib_symbols.append(
        '(symbol "C_Polarized" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "C", False)} {lib_prop("Value", "C", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "C_Polarized_0_1" '
        '(polyline (pts (xy -2.032 0.762) (xy 2.032 0.762)) (stroke (width 0.508) (type default)) (fill (type none))) '
        '(polyline (pts (xy -2.032 -0.762) (xy 2.032 -0.762)) (stroke (width 0.508) (type default)) (fill (type none))) '
        '(polyline (pts (xy -3.2 2.2) (xy -1.7 2.2)) (stroke (width 0.254) (type default)) (fill (type none))) '
        '(polyline (pts (xy -2.45 2.95) (xy -2.45 1.45)) (stroke (width 0.254) (type default)) (fill (type none)))) '
        '(symbol "C_Polarized_1_1" '
        f'{pin_expr(1, "+", 0, 3.81, 270, 3.048)} '
        f'{pin_expr(2, "-", 0, -3.81, 90, 3.048)}) (embedded_fonts no))')


def define_diode():
    lib_symbols.append(
        '(symbol "D_Schottky" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "D", False)} {lib_prop("Value", "D", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "D_Schottky_0_1" '
        '(polyline (pts (xy -1.27 1.27) (xy -1.27 -1.27) (xy 1.27 0) (xy -1.27 1.27)) '
        '(stroke (width 0.254) (type default)) (fill (type none))) '
        '(polyline (pts (xy 1.27 1.27) (xy 1.27 -1.27)) '
        '(stroke (width 0.254) (type default)) (fill (type none)))) '
        '(symbol "D_Schottky_1_1" '
        f'{pin_expr("A", "A", -3.81, 0, 0, 2.54)} '
        f'{pin_expr("K", "K", 3.81, 0, 180, 2.54)}) (embedded_fonts no))')


# ----------------------------------------------------------------- primitives
def wire(x1, y1, x2, y2):
    items.append(
        f'(wire (pts (xy {n(x1)} {n(y1)}) (xy {n(x2)} {n(y2)})) '
        f'(stroke (width 0) (type default)) (uuid "{u()}"))')


def junction(x, y):
    items.append(f'(junction (at {n(x)} {n(y)}) (diameter 0) (color 0 0 0 0) (uuid "{u()}"))')


def label(name, x, y, direction):
    ang, just = {"left": (180, "right bottom"), "right": (0, "left bottom"),
                 "up": (90, "left bottom"), "down": (270, "right bottom")}[direction]
    items.append(
        f'(label "{q(name)}" (at {n(x)} {n(y)} {ang}) '
        f'(effects (font (size 1.27 1.27)) (justify {just})) (uuid "{u()}"))')


def stub_label(name, x, y, direction, length=STUB):
    dx, dy = {"left": (-length, 0), "right": (length, 0),
              "up": (0, -length), "down": (0, length)}[direction]
    wire(x, y, x + dx, y + dy)
    label(name, x + dx, y + dy, direction)


def text(s, x, y, size=1.27, bold=False):
    b = " (bold yes)" if bold else ""
    items.append(
        f'(text "{q(s)}" (exclude_from_sim no) (at {n(x)} {n(y)} 0) '
        f'(effects (font (size {n(size)} {n(size)}){b}) (justify left bottom)) (uuid "{u()}"))')


def box(x1, y1, x2, y2):
    items.append(
        f'(rectangle (start {n(x1)} {n(y1)}) (end {n(x2)} {n(y2)}) '
        f'(stroke (width 0) (type dash)) (fill (type none)) (uuid "{u()}"))')


def instance(lib_id, ref, value, x, y, pin_numbers, ref_pos, val_pos, footprint=""):
    pins = " ".join(f'(pin "{q(str(p))}" (uuid "{u()}"))' for p in pin_numbers)
    items.append(
        f'(symbol (lib_id "{lib_id}") (at {n(x)} {n(y)} 0) (unit 1) '
        f'(exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no) (uuid "{u()}") '
        f'(property "Reference" "{ref}" (at {n(ref_pos[0])} {n(ref_pos[1])} 0) '
        f'(effects (font (size 1.27 1.27)) (justify left bottom))) '
        f'(property "Value" "{q(value)}" (at {n(val_pos[0])} {n(val_pos[1])} 0) '
        f'(effects (font (size 1.27 1.27)) (justify left bottom))) '
        f'(property "Footprint" "{q(footprint)}" (at {n(x)} {n(y)} 0) (effects (font (size 1.27 1.27)) (hide yes))) '
        f'(property "Datasheet" "" (at {n(x)} {n(y)} 0) (effects (font (size 1.27 1.27)) (hide yes))) '
        f'{pins} '
        f'(instances (project "{PROJECT}" (path "/{ROOT_UUID}" (reference "{ref}") (unit 1)))))')


# --------------------------------------------------------------------- blocks
def block(libname, title, x, y, left, right, ref_prefix="U", width=30.48, footprint=""):
    """left/right: [(pin_number, pin_name, net_or_None)] (None = unused pin)."""
    rows, top, width = define_block(libname, left, right, width)
    x, y = snap(x), snap(y)
    if rows % 2 == 0:
        y += 1.27  # keep pins on the 2.54 grid
    ref = next_ref(ref_prefix)
    instance(f"HastaDAQ:{libname}", ref, title, x, y,
             [a for a, _, _ in left + right],
             (x - width / 2, y - top - 3.81), (x - width / 2, y - top - 1.27), footprint)
    for lst, px, d in ((left, x - width / 2 - STUB, "left"), (right, x + width / 2 + STUB, "right")):
        for i, (_, _, net) in enumerate(lst):
            if net:
                stub_label(net, px, y - ((rows - 1) * 1.27 - i * 2.54), d)
    return ref


def header(title, x, y, pins, ref_prefix="J"):
    """pins: [(name, net)] -> one 1xN 0.1in header, pin numbers 1..N."""
    cnt = len(pins)
    names = "".join(c if c.isalnum() else "p" for c in "_".join(nm for nm, _ in pins))
    return block(f"Header1x{cnt:02d}_{names}", title, x, y,
                 left=[(i + 1, name, net) for i, (name, net) in enumerate(pins)], right=[],
                 ref_prefix=ref_prefix, width=15.24, footprint=FP_HDR.format(n=cnt))


def resistor(x, y, value):
    ref = next_ref("R")
    instance("HastaDAQ:R", ref, value, x, y, [1, 2],
             (x + 2.54, y - 1.27), (x + 2.54, y + 2.54), "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal")
    return (x, y - 3.81), (x, y + 3.81)  # pin1 (top), pin2 (bottom)


def vertical_part(libname, prefix, value, x, y, top_net, bot_net, footprint):
    """Vertical 2-pin part whose pins connect to net labels at the top/bottom."""
    x, y = snap(x), snap(y)
    ref = next_ref(prefix)
    instance(f"HastaDAQ:{libname}", ref, value, x, y, [1, 2],
             (x + 3.81, y - 1.27), (x + 3.81, y + 2.54), footprint)
    stub_label(top_net, x, y - 3.81, "up")
    stub_label(bot_net, x, y + 3.81, "down")
    return ref


def completion(xc, y0, mid_net, title):
    """Two fixed 350R resistors in series between +3V3 and GND; mid-point -> mid_net."""
    xc, y0 = snap(xc), snap(y0)
    r1_top, r1_bot = resistor(xc, y0, "350R fixed")
    r2_top, r2_bot = resistor(xc, y0 + 15.24, "350R fixed")
    ym = y0 + 7.62
    wire(xc, r1_bot[1], xc, ym)
    wire(xc, ym, xc, r2_top[1])
    junction(xc, ym)
    stub_label(mid_net, xc, ym, "right", 12.7)
    stub_label("+3V3", xc, r1_top[1], "up")
    stub_label("GND", xc, r2_bot[1], "down")
    box(xc - 10.16, r1_top[1] - 6.35, xc + 10.16, r2_bot[1] + 6.35)
    text(title, xc - 10.16, r1_top[1] - 12.7)


# ----------------------------------------------------------------------- main
define_resistor()
define_fuse()
define_cap()
define_cap_polarized()
define_diode()

# Pimoroni Pico Plus 2 -- all 40 header pins (Pico 2 W datasheet fig. 2; same header)
pico_left = [
    (1, "GP0 UART0-TX", None), (2, "GP1 UART0-RX", None), (3, "GND", "GND"),
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
block("PicoPlus2", "Pimoroni Pico Plus 2 (header pins)", 70, 140,
      pico_left, pico_right, width=60.96)

header("IMU via Qwiic breakout (The Pi Hut 106676)", 185, 45,
       [("GND", "GND"), ("3V3", "+3V3"), ("SDA", "SDA"), ("SCL", "SCL")])


def ads(title, y, a0, a1):
    block("ADS122C04", title, 185, y,
          left=[(1, "VIN", "+3V3"), (2, "GND", "GND"), (3, "SDA", "SDA"), (4, "SCL", "SCL"),
                (5, "~{RST}", None), (6, "DRDY", None)],
          right=[(7, "A0", a0), (8, "A1", a1), (9, "A2", None), (10, "A3", None),
                 (11, "Ref+", None), (12, "Ref-", None)])


ads("Adafruit ADS122C04 #1 (I2C 0x40)", 115, "ADS1_SIG", "ADS_REF")
ads("Adafruit ADS122C04 #2 (addr jumper bridged)", 200, "ADS2_SIG", "ADS_REF")

# half-bridge gauge modules: 3-pin header (V, SIG, GND); ONE completion pair at the ADCs, shared
header("HB1 half-bridge #1 (on beam)", 270, 105, [("V", "+3V3"), ("SIG", "ADS1_SIG"), ("GND", "GND")])
header("HB2 half-bridge #2 (on beam)", 270, 190, [("V", "+3V3"), ("SIG", "ADS2_SIG"), ("GND", "GND")])
completion(330, 140, "ADS_REF", "Shared completion\nresistors (fixed)\n-> A1 of BOTH ADCs")


def adc_decoupling(adc, y):
    """10uF + 100nF supply decoupling at the ADC (no input filter)."""
    c_fp = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"
    vertical_part("C", "C", "10uF", 285, y, "+3V3", "GND", c_fp)  # X7R, >=10V
    vertical_part("C", "C", "100nF", 300, y, "+3V3", "GND", c_fp)  # X7R
    box(278, y - 12, 313, y + 12)
    text(f"ADS{adc} supply decoupling (place at ADC)", 278, y - 14)


adc_decoupling(1, 60)
adc_decoupling(2, 152)

# encoders: three 2x4 0.1in headers on one SPI bus, each with its own CS.
# Pins 1..8 in order: GND, CS, SCK, MOSI, MISO, 3V3, 5V, GND. 3V3 powers an MT6835,
# 5V powers an RLS Orbis (3.3 V logic). Pull-ups keep unselected CS lines high at boot.
FP_HDR_2X4 = "Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical"


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
block("D42V55F8", "Pololu D42V55F8 8.4V 5A buck (servo rail)", 140, 300,
      left=[(2 * k + 1, nm, net) for k, (nm, net) in enumerate(POL_FAR)],
      right=[(2 * k + 2, nm, net) for k, (nm, net) in enumerate(POL_NEAR)],
      ref_prefix="U", width=30.48,
      footprint="Connector_PinHeader_2.54mm:PinHeader_2x06_P2.54mm_Vertical")
# SparkFun BabyBuck 5V (AP63357, 6-32 V in, ~3 A): 4 pins on 0.1" pitch, order along the header
# as read off the module: 5V GND VIN EN. EN (rated to 32 V) is tied to VIN so the output is always on.
block("BabyBuck_5V", "SparkFun BabyBuck 5V (AP63357) (Pico VSYS, Orbis)", 140, 340,
      left=[(3, "VIN", "+12V"), (2, "GND", "GND"), (4, "EN", "+12V")],
      right=[(1, "VOUT 5V", "+5V")],
      ref_prefix="U", width=30.48, footprint="Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical")
vertical_part("Fuse", "F", "Fuse (size to servo load)", 250, 300, "+12V_IN", "+12V",
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

# SBUS out: one 3x6 servo header, 6 servo plugs side by side. Servo k = pins 3k-2 (V), 3k-1 (SIG), 3k (GND);
# V = VSERVO, SIG = SBUS (all six in parallel), GND. Footprint is the project's own HastaDAQ:PinHeader_3x06
# (KiCad has no 3x6 header): 6 columns on 2.54 mm, rows V / SIG / GND, pad 1 square.
FP_SBUS = "HastaDAQ:PinHeader_3x06_P2.54mm_Vertical"
sbus_pins = []
for k in range(6):
    sbus_pins += [(3 * k + 1, f"S{k + 1} V", "VSERVO"), (3 * k + 2, f"S{k + 1} SIG", "SBUS"),
                  (3 * k + 3, f"S{k + 1} GND", "GND")]
block("Header3x06_SBUS", "SBUS servo header 3x6 (6 x V, SIG, GND)", 380, 75,
      left=sbus_pins, right=[], ref_prefix="J", width=15.24, footprint=FP_SBUS)

# Main supply cable: 2x4 0.1in header, pins 1..8 row-major (1,2 / 3,4 / 5,6 / 7,8). Functions are placed
# so a connector plugged in rotated 180 deg (pin i <-> 9-i) still gets supply on supply and ground on
# ground; use a keyed/shrouded header to stop the mirrored mis-plug. SOFTSTOP+ / SOFTSTOP- are the two
# ends of a normally-closed loop at the far end: SOFTSTOP- is board GND, SOFTSTOP+ goes through 1k to a
# Pico GPIO that is pulled up to 3V3. Loop intact = low = run; loop broken (cable pulled, switch open) =
# high = stop the manoeuvre in firmware.
FP_HDR_2X4 = "Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical"
pw_pins = [("VSUPPLY", "+12V_IN"), ("VGND", "GND"), ("TRIG_IN", "TRIG_IN"), ("SOFTSTOP+", "SOFTSTOP_CABLE"),
           ("SOFTSTOP-", "GND"), ("TRIG_OUT", "TRIG_OUT"), ("VGND", "GND"), ("VSUPPLY", "+12V_IN")]
pw_names = "".join(c if c.isalnum() else "p" for c in "_".join(nm for nm, _ in pw_pins))
block(f"Header2x04_{pw_names}", "Main supply cable (2x4): VSUPPLY, VGND, TRIG, SOFTSTOP", 380, 215,
      left=[(i + 1, name, net) for i, (name, net) in enumerate(pw_pins)], right=[],
      ref_prefix="J", width=15.24, footprint=FP_HDR_2X4)
r_fp = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal"
vertical_part("R", "R", "1k (soft-stop series)", 330, 260, "SOFTSTOP_CABLE", "SOFTSTOP_IN", r_fp)
vertical_part("R", "R", "10k (soft-stop pull-up)", 385, 260, "+3V3", "SOFTSTOP_IN", r_fp)

# Trigger I/O conditioning for 3.3 V .. 24 V equipment (all through hole).
# TRIG_IN : cable -> 1k/1W -> PC817 LED (1N4148 antiparallel, 10k pull-down on the cable side);
#           opto transistor pulls TRIG_IN_GPIO (GP14) low, 10k pull-up to 3V3. Inverted: active = low.
# TRIG_OUT: GP15 -> 100R -> 2N7000 gate (100k pull-down); drain = TRIG_OUT cable line. Open drain,
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

text("TRIGGER OUT: open-drain, pull-up rail chosen by jumper", 430, 285)
vertical_part("R", "R", "100R", 435, 315, "TRIG_OUT_GPIO", "TRIG_OUT_GATE", FP_R)
vertical_part("R", "R", "100k", 455, 315, "TRIG_OUT_GATE", "GND", FP_R)
block("2N7000", "2N7000 (TO-92: check pinout S/G/D)", 495, 315,
      left=[(2, "G", "TRIG_OUT_GATE")],
      right=[(3, "D", "TRIG_OUT"), (1, "S", "GND")],
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

text("HastaDAQ", 20, 20, 3.0, bold=True)
text("Net labels connect everything: same name = same net. +3V3 / GND are plain labels, not power symbols.", 20, 27)
text("Pimoroni Pico Plus 2 (+ RM2 on SP/CE): same 40-pin header as Pico 2 W. I2C0 = GP4/GP5 (header pins 6/7), hard-wired\n"
     "to the IMU Qwiic-breakout header and both ADS122C04 boards by header pins. Crossed-out pins are intentionally unused.", 20, 36)
text("NOTES\n"
     "1. ONE common GND (Pico, sensors, servo PSU). SBUS needs a shared ground reference.\n"
     "   RM2 WiFi breakout (off-board, cabled to the Pico Plus 2 SP/CE connector): uses GP32-GP36 only, no overlap with I2C (GP4/5) or any other signal.\n"
     "2. ADS2: bridge one address jumper on its back (A0/A1); resulting address unconfirmed --\n"
     "   firmware falls back to an I2C scan at boot. I2C pull-ups: rely on the Adafruit breakouts' on-board pull-ups.\n"
     "3. Each half-bridge module (2 gauges) plugs into a 3-pin header: V, SIG (mid-point), GND. SIG -> A0 of its ADC, direct\n"
     "   (no input filter). ONE shared pair of fixed 350R completion resistors; its mid-point (ADS_REF) goes to A1 of BOTH\n"
     "   ADCs. Excitation is the ADC's own VIN, so VREF_SUPPLY is ratiometric -- no Ref+/Ref- wiring.\n"
     "4. SBUS: GP20 (TX) and GP21 (RX) on one net (UART inverted in firmware). One 3x6 servo header (6 plugs of V, SIG, GND;\n"
     "   footprint HastaDAQ:PinHeader_3x06): V = VSERVO (8.4 V), SIG = SBUS (all six in parallel), GND.\n"
     "5. POWER: 12 V in -> fuse -> +12V rail -> (a) Pololu D42V55F8 = VSERVO 8.4 V (servos), (b) SparkFun BabyBuck 5V = +5V (Orbis,\n"
     "   Schottky -> Pico VSYS). VSYS max is 5.5 V. USB (VBUS) is left for programming; with USB only, +5V is not live.\n"
     "6. Trigger pins are 3.3 V logic only. Pin order on the headers: see each symbol.\n"
     "   Main supply cable (2x4, pins 1-8 row-major): 1,8 VSUPPLY (12 V) | 2,7 VGND | 3 TRIG_IN | 6 TRIG_OUT | 4 SOFTSTOP+ | 5 SOFTSTOP-.\n"
     "   SOFTSTOP+ -> 1k -> GP16 (10k pull-up to 3V3), SOFTSTOP- = GND: loop closed = run, loop broken = stop (fail-safe on a cable break).\n"
     "   Use a keyed/shrouded header; a 0.1in header pin is only good for ~1-3 A, so check the servo peak current against 2 supply pins.\n"
     "7. Encoders: 4 x 2x4 headers (pins 1-8: GND, CS, SCK, MOSI, MISO, 3V3, 5V, GND) on one SPI1 bus; CS = GP13/GP9/GP8/GP7.\n"
     "   MT6835 uses 3V3 (3.3 V logic); RLS Orbis uses 5V with 3.3 V logic. Check MISO tri-states when CS is high.\n"
     "   The four ENC headers are a generic SPI port (SPI1: SCK GP10, MOSI GP11, MISO GP12, own CS each, 3V3 and 5V supply), so any 3.3 V\n"
     "   SPI device can be plugged in, not just encoders. Each device needs its own CS and an MISO that tri-states when CS is high.\n"
     "8. Use shielded twisted cable for the gauge wires, shield to GND at the ADC end only.",
     20, 405)

embedded_symbols = [s.replace('(symbol "', '(symbol "HastaDAQ:', 1) for s in lib_symbols]

sch = (
    f'(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0") '
    f'(uuid "{ROOT_UUID}") (paper "A2") '
    f'(title_block (title "HastaDAQ") (rev "A") (company "HastaArduino")) '
    f'(lib_symbols {" ".join(embedded_symbols)}) '
    + " ".join(items) +
    ' (sheet_instances (path "/" (page "1"))) (embedded_fonts no))'
)

OUT_DIR.mkdir(parents=True, exist_ok=True)
(OUT_DIR / f"{PROJECT}.kicad_sch").write_text(sch, encoding="utf-8")
(OUT_DIR / "HastaDAQ.kicad_sym").write_text(
    '(kicad_symbol_lib (version 20241209) (generator "kicad_symbol_editor") '
    '(generator_version "9.0") ' + " ".join(lib_symbols) + ")", encoding="utf-8")
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
    '  (descr "3x6 pin header, 2.54 mm pitch: 6 servo plugs side by side, rows V / SIG / GND")\n'
    '  (tags "servo header 3x6 2.54mm")\n'
    '  (property "Reference" "REF**" (at 6.35 -2.54 0) (layer "F.SilkS") (effects (font (size 1 1) (thickness 0.15))))\n'
    '  (property "Value" "PinHeader_3x06_P2.54mm_Vertical" (at 6.35 7.62 0) (layer "F.Fab") (effects (font (size 1 1) (thickness 0.15))))\n'
    '  (attr through_hole)\n'
    f'  (fp_rect (start -1.27 -1.27) (end {n(x2)} {n(y2)}) (stroke (width 0.12) (type default)) (fill none) (layer "F.SilkS"))\n'
    f'  (fp_rect (start -1.77 -1.77) (end {n(x2 + 0.5)} {n(y2 + 0.5)}) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd"))\n'
    + "\n".join(pads) + "\n)\n")
(pretty / "PinHeader_3x06_P2.54mm_Vertical.kicad_mod").write_text(fpmod, encoding="utf-8")
(OUT_DIR / "fp-lib-table").write_text(
    '(fp_lib_table\n  (version 7)\n'
    '  (lib (name "HastaDAQ")(type "KiCad")(uri "${KIPRJMOD}/HastaDAQ.pretty")(options "")(descr "HastaDAQ custom footprints"))\n)\n',
    encoding="utf-8")
(OUT_DIR / "sym-lib-table").write_text(
    '(sym_lib_table\n  (version 7)\n'
    '  (lib (name "HastaDAQ")(type "KiCad")(uri "${KIPRJMOD}/HastaDAQ.kicad_sym")(options "")(descr "HastaDAQ rig modules"))\n)\n',
    encoding="utf-8")
pro = OUT_DIR / f"{PROJECT}.kicad_pro"
if not pro.exists():
    pro.write_text('{\n  "meta": {\n    "filename": "hastadaq.kicad_pro",\n    "version": 3\n  }\n}\n',
                   encoding="utf-8")
print("wrote", OUT_DIR / f"{PROJECT}.kicad_sch")
