"""Bootstrap generator for kicad/hastadaq/hastadaq.kicad_sch.

Run once to create the first draft; after that the .kicad_sch is the source of
truth and is meant to be edited in KiCad (this script will overwrite edits).

    py kicad/tools/generate_hastadaq_sch.py

Connectivity is by local net labels (no long wires) so the sheet stays
readable; only the completion-resistor dividers are drawn with real wires.
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
             (x + 2.54, y - 1.27), (x + 2.54, y + 2.54), "Resistor_SMD:R_0805_2012Metric")
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
    (9, "GP6", None), (10, "GP7", None), (11, "GP8", None), (12, "GP9", None), (13, "GND", "GND"),
    (14, "GP10 SPI1-SCK", "SPI_SCK"), (15, "GP11 SPI1-TX", "SPI_MOSI"),
    (16, "GP12 SPI1-RX", "SPI_MISO"), (17, "GP13 SPI1-CSn", "SPI_CS"), (18, "GND", "GND"),
    (19, "GP14", "TRIG_IN"), (20, "GP15", "TRIG_OUT"),
]
pico_right = [
    (40, "VBUS", None), (39, "VSYS", "+5V_VSYS"), (38, "GND", "GND"), (37, "3V3_EN", None),
    (36, "3V3(OUT)", "+3V3"), (35, "ADC_VREF", None), (34, "GP28", None), (33, "AGND", "GND"),
    (32, "GP27", None), (31, "GP26", None), (30, "RUN", None), (29, "GP22", None),
    (28, "GND", "GND"), (27, "GP21 UART1-RX", "SBUS"), (26, "GP20 UART1-TX", "SBUS"),
    (25, "GP19", None), (24, "GP18", None), (23, "GND", "GND"), (22, "GP17", None), (21, "GP16", None),
]
block("PicoPlus2", "Pimoroni Pico Plus 2 (header pins)", 70, 140,
      pico_left, pico_right, width=60.96)

block("ICM20649", "Adafruit ICM20649 IMU (Qwiic, 0x68)", 185, 45,
      left=[(1, "3V3", "+3V3"), (2, "GND", "GND"), (3, "SDA", "SDA"), (4, "SCL", "SCL")], right=[])


def ads(title, y, a0, a1):
    block("ADS122C04", title, 185, y,
          left=[(1, "VIN", "+3V3"), (2, "GND", "GND"), (3, "SDA", "SDA"), (4, "SCL", "SCL"),
                (5, "~{RST}", None), (6, "DRDY", None)],
          right=[(7, "A0", a0), (8, "A1", a1), (9, "A2", None), (10, "A3", None),
                 (11, "Ref+", None), (12, "Ref-", None)])


ads("Adafruit ADS122C04 #1 (I2C 0x40)", 115, "ADS1_AIN0", "ADS1_AIN1")
ads("Adafruit ADS122C04 #2 (addr jumper bridged)", 200, "ADS2_AIN0", "ADS2_AIN1")

# half-bridge gauge modules: 3-pin header (V, SIG, GND) + completion resistors at the ADC
header("HB1 half-bridge #1 (on beam)", 270, 105, [("V", "+3V3"), ("SIG", "ADS1_SIG"), ("GND", "GND")])
completion(330, 98, "ADS1_OUTN", "ADS1 completion\nresistors (fixed)")
header("HB2 half-bridge #2 (on beam)", 270, 190, [("V", "+3V3"), ("SIG", "ADS2_SIG"), ("GND", "GND")])
completion(330, 183, "ADS2_OUTN", "ADS2 completion\nresistors (fixed)")


def bridge_filter(adc, y):
    """1k series on each bridge output + 100nF differential at the ADC inputs,
    plus 10uF + 100nF supply decoupling (all close to the ADC)."""
    sig, outn = f"ADS{adc}_SIG", f"ADS{adc}_OUTN"
    ain0, ain1 = f"ADS{adc}_AIN0", f"ADS{adc}_AIN1"
    r_fp, c_fp = "Resistor_SMD:R_0805_2012Metric", "Capacitor_SMD:C_0805_2012Metric"
    vertical_part("R", "R", "1k", 240, y, sig, ain0, r_fp)
    vertical_part("R", "R", "1k", 255, y, outn, ain1, r_fp)
    vertical_part("C", "C", "100nF", 270, y, ain0, ain1, c_fp)  # differential, C0G/X7R
    vertical_part("C", "C", "10uF", 285, y, "+3V3", "GND", c_fp)  # X7R, >=10V
    vertical_part("C", "C", "100nF", 300, y, "+3V3", "GND", c_fp)  # X7R
    box(233, y - 22, 313, y + 22)
    text(f"ADS{adc} input filter + supply decoupling (place at ADC)", 233, y - 24)


bridge_filter(1, 60)
bridge_filter(2, 152)

# pitch encoder: 6-pin header
header("Pitch encoder (MT6835)", 70, 205,
       [("GND", "GND"), ("CS", "SPI_CS"), ("CLK", "SPI_SCK"),
        ("MOSI", "SPI_MOSI"), ("MISO", "SPI_MISO"), ("V", "+3V3")])

# RM2 WiFi breakout on the Pico Plus 2 SP/CE connector (8-pin JST-SH, 1:1 cable).
# Pin order and GPIO numbers from Pimoroni's Pico Plus 2 pinout diagram; the RM2
# signals match the firmware's CYW43_PINS_SPCE table (REG_ON=GP32, CS=GP33, CLK=GP34, DATA=GP35).
spce_pins = [(1, "VSYS", "+5V_VSYS"), (2, "3V3", "+3V3"), (3, "CS GP33", "RM2_CS"),
             (4, "SCK GP34", "RM2_CLK"), (5, "TX GP35", "RM2_DATA"), (6, "RX GP32", "RM2_REG_ON"),
             (7, "BL GP36", None), (8, "GND", "GND")]
block("SPCE_JST8", "Pico Plus 2 SP/CE connector (8-pin JST-SH)", 40, 75,
      left=[], right=spce_pins, ref_prefix="J", width=30.48)
block("RM2", "Pimoroni RM2 WiFi/BT breakout (1:1 JST-SH cable)", 125, 75,
      left=spce_pins, right=[], ref_prefix="U", width=30.48)

# power: 8.4 V bench PSU -> fuse -> VSERVO (servos direct + UBEC input);
# UBEC 5 V -> Schottky -> Pico VSYS
block("UBEC", "UBEC 5A (set to 5V! input must accept 8.4V)", 140, 240,
      left=[(1, "VIN", "VSERVO"), (2, "GND", "GND")], right=[(3, "5V_OUT", "+5V_IN")],
      width=30.48, footprint="")
vertical_part("Fuse", "F", "Fuse (size to servo load)", 250, 240, "+8V4_IN", "VSERVO",
              "Fuse:Fuse_1812_4532Metric")
vertical_part("C_Polarized", "C", "470-1000uF bulk (>=16V)", 285, 240, "VSERVO", "GND",
              "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm")
ref_d = next_ref("D")
dx, dy = snap(210), snap(240)
instance("HastaDAQ:D_Schottky", ref_d, "Schottky (e.g. SS34)", dx, dy, ["A", "K"],
         (dx - 5, dy - 5.08), (dx - 5, dy - 2.54), "Diode_SMD:D_SMA")
stub_label("+5V_IN", dx - 3.81, dy, "left")
stub_label("+5V_VSYS", dx + 3.81, dy, "right")

# SBUS bus out: one 3-pin 0.1in header (V, SIG, GND) to the servo bus
header("SBUS out (V, SIG, GND)", 390, 100, [("V", "VSERVO"), ("SIG", "SBUS"), ("GND", "GND")])

# "Power connector": one 8-wire cable carrying the bench supply, sensor ground
# and both trigger lines. Pins 1/8 = GND, 2/7 = V supply (8.4 V), 3/6 = sensor
# GND, 4 = trigger OUT, 5 = trigger IN. Paired pins (1+8, 2+7, 3+6) are
# doubled up for current / redundancy, so each pair is the same net. Sensor
# GND is tied to the one common GND here (see note 1).
header("Power connector (8-wire): supply, GND, triggers", 390, 215,
       [("GND", "GND"), ("VSUPPLY", "+8V4_IN"), ("GND_SENSOR", "GND"),
        ("TRIG_OUT", "TRIG_OUT"), ("TRIG_IN", "TRIG_IN"), ("GND_SENSOR", "GND"),
        ("VSUPPLY", "+8V4_IN"), ("GND", "GND")])

text("HastaDAQ", 20, 20, 3.0, bold=True)
text("Net labels connect everything: same name = same net. +3V3 / GND are plain labels, not power symbols.", 20, 27)
text("Pimoroni Pico Plus 2 (+ RM2 on SP/CE): same 40-pin header as Pico 2 W. Qwiic port = GP4/GP5 (I2C0), same nets as\n"
     "header pins 6/7 and 3V3 as pin 36. Each ADS122C04 board also has two Qwiic connectors in parallel with its\n"
     "VIN/GND/SDA/SCL pins. Crossed-out pins are intentionally unused.", 20, 36)
text("NOTES\n"
     "1. ONE common GND (Pico, sensors, servo PSU). SBUS needs a shared ground reference.\n"
     "   RM2 WiFi breakout: SP/CE uses GP32-GP36 only, no overlap with Qwiic (GP4/5) or any other signal.\n"
     "2. ADS2: bridge one address jumper on its back (A0/A1); resulting address unconfirmed --\n"
     "   firmware falls back to an I2C scan at boot.\n"
     "3. Each half-bridge module (2 gauges) plugs into a 3-pin header: V, SIG (mid-point), GND. The two fixed\n"
     "   350R completion resistors sit next to the ADC; their mid-point goes to A1. Excitation is the ADC's own\n"
     "   VIN, so VREF_SUPPLY is ratiometric -- no Ref+/Ref- wiring.\n"
"4. SBUS: GP20 (TX) and GP21 (RX) on one net (UART inverted in firmware).\n"
     "5. POWER: 8.4 V bench PSU -> fuse -> VSERVO feeds the servos directly and the UBEC input. UBEC 5 V -> Schottky ->\n"
     "   Pico VSYS. Pico VSYS max is 5.5 V (datasheet), so the UBEC MUST be set to 5 V, not 6 V. Confirm the UBEC's\n"
     "   input range covers 8.4 V. USB (VBUS) is left for programming. Set a current limit on the bench PSU.\n"
     "6. Trigger pins are 3.3 V logic only. Pin order on the headers: see each symbol.\n"
     "   Power connector (8-wire): 1,8 GND | 2,7 V supply (8.4 V) | 3,6 sensor GND | 4 trigger OUT | 5 trigger IN.\n"
     "   Sensor GND (3,6) is drawn tied to the common GND; split it only if the sensor return must stay separate.\n"
     "7. Per ADC: 1k in each bridge-output leg + 100nF across them (~800 Hz corner), and 10uF + 100nF across the\n"
     "   bridge supply. Place these at the ADC end. Use shielded twisted cable for the gauge wires, shield to GND at\n"
     "   the ADC end only.",
     110, 281)

embedded_symbols = [s.replace('(symbol "', '(symbol "HastaDAQ:', 1) for s in lib_symbols]

sch = (
    f'(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0") '
    f'(uuid "{ROOT_UUID}") (paper "A3") '
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
(OUT_DIR / "sym-lib-table").write_text(
    '(sym_lib_table\n  (version 7)\n'
    '  (lib (name "HastaDAQ")(type "KiCad")(uri "${KIPRJMOD}/HastaDAQ.kicad_sym")(options "")(descr "HastaDAQ rig modules"))\n)\n',
    encoding="utf-8")
pro = OUT_DIR / f"{PROJECT}.kicad_pro"
if not pro.exists():
    pro.write_text('{\n  "meta": {\n    "filename": "hastadaq.kicad_pro",\n    "version": 3\n  }\n}\n',
                   encoding="utf-8")
print("wrote", OUT_DIR / f"{PROJECT}.kicad_sch")
