"""Generates the plug-in module footprints into kicad/hastadaq/HastaDAQ.pretty.

    py kicad/tools/generate_module_footprints.py

Each footprint is the module's through-hole pad pattern (what the carrier PCB must match) plus the
module outline on F.Fab/F.SilkS and a courtyard. Pad NUMBERS match the pin numbers of the schematic
symbols in generate_hastadaq_sch.py, so assigning the footprint needs no re-numbering. Sources:

  Adafruit ADS122C04   : Adafruit EagleCAD board file (github.com/adafruit/Adafruit-ADS122C04-24-Bit-ADC-PCB),
                         two 1x6 headers 12.7 mm apart, 25.4 x 17.78 mm board, 4x 2.5 mm holes.
  SparkFun BabyBuck 5V : SparkFun Eagle board file (SparkFun_Buck_Regulator_AP63357DV-7_BabyBuck5V.brd),
                         one 1x4 header, 15.875 x 13.208 mm board, no mounting holes.
  Pololu D42V55Fx      : Pololu dimension drawing (0J2180) + pinout photo (0J13518); 25.4 mm square,
                         3x 2.18 mm holes, 12 pads 1.02 mm drill on a 2x6 2.54 mm grid.

Coordinates: mm, KiCad convention (y down), origin on pad 1.
"""
import pathlib
import uuid

OUT = pathlib.Path(__file__).resolve().parent.parent / "hastadaq" / "HastaDAQ.pretty"
PAD_D, DRILL = 1.7, 1.0


def fmt(v):
    return f"{round(v, 4):g}"


def make_fp(name, descr, tags, pads, outline, holes, labels, notes=(), courtyard=None, model=None):
    """pads: [(number, x, y)]; outline: (x1, y1, x2, y2); holes: [(x, y, drill)];
    labels: [(text, x, y)] drawn on F.Fab; notes: [(text, x, y)] on F.Fab."""
    x1, y1, x2, y2 = outline
    cx1, cy1, cx2, cy2 = courtyard if courtyard else outline
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    m = 0.25  # courtyard margin
    out = [
        f'(footprint "{name}"',
        '  (version 20240108)', '  (generator "pcbnew")', '  (generator_version "8.0")',
        '  (layer "F.Cu")', f'  (descr "{descr}")', f'  (tags "{tags}")',
        f'  (property "Reference" "REF**" (at {fmt(cx)} {fmt(y1 - 1.5)} 0) (layer "F.SilkS") '
        '(effects (font (size 1 1) (thickness 0.15))))',
        f'  (property "Value" "{name}" (at {fmt(cx)} {fmt(y2 + 1.5)} 0) (layer "F.Fab") '
        '(effects (font (size 1 1) (thickness 0.15))))',
        '  (attr through_hole)',
        f'  (fp_rect (start {fmt(cx1)} {fmt(cy1)}) (end {fmt(cx2)} {fmt(cy2)}) '
        '(stroke (width 0.12) (type default)) (fill none) (layer "F.SilkS"))',
        f'  (fp_rect (start {fmt(x1)} {fmt(y1)}) (end {fmt(x2)} {fmt(y2)}) '
        '(stroke (width 0.1) (type default)) (fill none) (layer "F.Fab"))',
        f'  (fp_rect (start {fmt(cx1 - m)} {fmt(cy1 - m)}) (end {fmt(cx2 + m)} {fmt(cy2 + m)}) '
        '(stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd"))',
    ]
    for text, x, y in list(labels) + list(notes):
        out.append(f'  (fp_text user "{text}" (at {fmt(x)} {fmt(y)}) (layer "F.Fab") '
                   '(effects (font (size 0.6 0.6) (thickness 0.1))))')
    for num, x, y in pads:
        shape = "rect" if str(num) == "1" else "circle"
        out.append(f'  (pad "{num}" thru_hole {shape} (at {fmt(x)} {fmt(y)}) (size {PAD_D} {PAD_D}) '
                   f'(drill {DRILL}) (layers "*.Cu" "*.Mask"))')
    for x, y, d in holes:
        out.append(f'  (pad "" np_thru_hole circle (at {fmt(x)} {fmt(y)}) (size {d} {d}) '
                   f'(drill {d}) (layers "*.Cu" "*.Mask"))')
    if model:
        path, (ox, oy, oz) = model
        out.append(f'  (model "{path}" (offset (xyz {fmt(ox)} {fmt(oy)} {fmt(oz)})) '
                   '(scale (xyz 1 1 1)) (rotate (xyz 0 0 0)))')
    out.append(")")
    return "\n".join(out) + "\n"


def write(name, text):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.kicad_mod").write_text(text, encoding="utf-8")
    print("wrote", OUT / f"{name}.kicad_mod")


# ---------------------------------------------------------------- ADS122C04 (Adafruit)
# Pad number = symbol pin number. Row A (y=0): VIN GND SCL SDA DRDY RST. Row B (y=-12.7):
# Ref+ A0 A1 A2 A3 Ref-. Origin on the VIN pad.
ads_pads = [
    (1, 0.0, 0.0), (2, 2.54, 0.0), (4, 5.08, 0.0), (3, 7.62, 0.0), (6, 10.16, 0.0), (5, 12.7, 0.0),
    (11, 0.0, -12.7), (7, 2.54, -12.7), (8, 5.08, -12.7), (9, 7.62, -12.7), (10, 10.16, -12.7), (12, 12.7, -12.7),
]
ads_names = {1: "VIN", 2: "GND", 4: "SCL", 3: "SDA", 6: "DRDY", 5: "RST",
             11: "Ref+", 7: "A0", 8: "A1", 9: "A2", 10: "A3", 12: "Ref-"}
ads_labels = [(ads_names[n], x, y - 2.3 if y == 0 else y + 2.3) for n, x, y in ads_pads]
write("Adafruit_ADS122C04_Breakout", make_fp(
    "Adafruit_ADS122C04_Breakout",
    "Adafruit ADS122C04 24-bit ADC breakout, two 1x6 headers 12.7 mm apart (top view); 25.4 x 17.78 mm, "
    "4x 2.5 mm mounting holes; pad numbers = schematic symbol pins",
    "adafruit ads122c04 breakout module", ads_pads,
    (-6.35, -15.24, 19.05, 2.54),
    [(-3.81, 0.0, 2.5), (16.51, 0.0, 2.5), (-3.81, -12.7, 2.5), (16.51, -12.7, 2.5)],
    ads_labels))

# ---------------------------------------------------------------- BabyBuck 5V (SparkFun)
# Eagle pads: 1 EN, 2 VIN, 3 GND, 4 5V (vertical line near the right edge). Pad numbers here follow the
# schematic symbol instead: 1 = 5V, 2 = GND, 3 = VIN, 4 = EN, i.e. 5V at the bottom, EN at the top.
bb_pads = [(1, 0.0, 0.0), (2, 0.0, -2.54), (3, 0.0, -5.08), (4, 0.0, -7.62)]
bb_names = {1: "5V", 2: "GND", 3: "VIN", 4: "EN"}
write("SparkFun_BabyBuck_5V", make_fp(
    "SparkFun_BabyBuck_5V",
    "SparkFun BabyBuck 5V (AP63357) buck regulator, 1x4 header near one edge (top view); 15.875 x 13.208 mm; "
    "pad order bottom to top: 5V GND VIN EN; pad numbers = schematic symbol pins",
    "sparkfun babybuck ap63357 module", bb_pads,
    (-14.478, -9.398, 1.397, 3.81), [],
    [(bb_names[n], x - 3.0, y) for n, x, y in bb_pads]))

# ---------------------------------------------------------------- Pololu D42V55Fx
# Top view with the pads along the bottom edge. Column i (0..5) = VOUT GND GND VIN VRP PG|EN.
# "far" row (inner, 3.81 mm from the edge) = odd pads, "near" row (edge, 1.27 mm) = even pads.
# VOUT/GND/VIN/VRP are duplicated on both rows; PG is the inner pad and EN the edge pad of the last column.
pol_names = ["VOUT", "GND", "GND", "VIN", "VRP", "PG"]
pol_pads = []
for i in range(6):
    pol_pads.append((2 * i + 1, 2.54 * i, 0.0))     # far / inner row
    pol_pads.append((2 * i + 2, 2.54 * i, 2.54))    # near / edge row
pol_labels = [(pol_names[i], 2.54 * i, -1.9) for i in range(6)]
write("Pololu_D42V55Fx", make_fp(
    "Pololu_D42V55Fx",
    "Pololu D42V55Fx step-down regulator (top view, pads along the bottom edge); 25.4 mm square, "
    "3x 2.18 mm holes; columns VOUT GND GND VIN VRP PG(inner)/EN(edge); odd pads = inner row, even = edge row; "
    "6.1 mm tall above the board for the D42V55F8 (item 5575), 1.4 mm below",
    "pololu d42v55 regulator module", pol_pads,
    (-6.35, -21.59, 19.05, 3.81),
    [(-4.15, 1.61, 2.18), (16.95, 1.61, 2.18), (16.95, -19.49, 2.18)],
    pol_labels,
    notes=[("inner row = odd pads, edge row = even", 6.35, -9.0), ("EN = last column, edge row", 6.35, -7.8)]))

# ------------------------------------------------- Qwiic breakout (The Pi Hut 106676) on a 1x4 socket
# J1 in the schematic: 1x04 header GND 3V3 SDA SCL. The breakout's top edge carries the same four pads
# left to right; its board (from the supplied STEP) is 18.77 x 14.53 mm x 1.6 mm, header row 2.27 mm below
# the top edge, header centred on the board. Drawn on F.Fab with the STEP as the 3D model, lying flat on
# top of an 8.5 mm female socket (QWIIC_Z = socket height: change it if you use a different socket or
# mount the breakout differently). The courtyard covers only the socket row so it does not block routing.
QWIIC_Z = 8.5
q_pads = [(1, 0.0, 0.0), (2, 2.54, 0.0), (3, 5.08, 0.0), (4, 7.62, 0.0)]
q_names = {1: "GND", 2: "3V3", 3: "SDA", 4: "SCL"}
write("Qwiic_Breakout_1x4_Socket", make_fp(
    "Qwiic_Breakout_1x4_Socket",
    "1x4 header/socket (GND 3V3 SDA SCL) for the Pi Hut Qwiic breakout 106676 (18.77 x 14.53 mm board, header on "
    "the top edge, outline and 3D model from the supplied STEP); also fine for four plain wires",
    "qwiic breakout imu header 1x04", q_pads,
    (-5.593, -2.273, 13.18, 12.26), [],
    [(q_names[n], x, y + 2.0) for n, x, y in q_pads],
    courtyard=(-1.27, -1.27, 8.89, 1.27),
    model=("${KIPRJMOD}/HastaDAQ.3dshapes/QWIIC_Breakout_106676.step", (-17.785, -125.563, QWIIC_Z))))
