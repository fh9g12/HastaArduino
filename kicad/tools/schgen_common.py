"""Shared helpers for the HastaDAQ KiCad schematic generators.

Used by generate_hastadaq_sch.py (main board) and generate_gauge_sch.py (strain-gauge board).
A generator calls init(...), builds its sheet with block()/header()/vertical_part()/... and then
write_outputs(...). All helper state (symbol library, items, reference counters) is module-level
and is reset by init(), so one process builds one schematic.

Connectivity is by net labels; pins that are wired default to "passive" (a 4th tuple element on a
pin sets a real electrical type), unused pins are "no_connect".
"""
import pathlib
import uuid

PROJECT = ""
OUT_DIR = None
ROOT_UUID = ""
TITLE = ""
PAPER = "A2"

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
        for i, t in enumerate(lst):
            num, name, net = t[:3]
            ptype = "no_connect" if net is None else (t[3] if len(t) > 3 else "passive")
            y = (rows - 1) * 1.27 - i * 2.54
            pins.append(pin_expr(num, name, x, y, ang, STUB, ptype))
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


def define_testpoint():
    lib_symbols.append(
        '(symbol "TestPoint" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "TP", False)} {lib_prop("Value", "TP", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "TestPoint_0_1" (circle (center 0 0.508) (radius 0.762) '
        '(stroke (width 0.254) (type default)) (fill (type none)))) '
        '(symbol "TestPoint_1_1" '
        f'{pin_expr(1, "", 0, 2.54, 270, 1.27)}) (embedded_fonts no))')


def define_pwrflag():
    # zero-length power_out pin: tells ERC the net is supplied (used on nets fed
    # through a passive part such as the fuse, a diode or a connector)
    lib_symbols.append(
        '(symbol "PWR_FLAG" (power) (pin_numbers (hide yes)) (pin_names (offset 0) (hide yes)) '
        '(exclude_from_sim no) (in_bom no) (on_board yes) '
        f'{lib_prop("Reference", "#FLG", False)} {lib_prop("Value", "PWR_FLAG", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "PWR_FLAG_0_1" '
        '(polyline (pts (xy 0 0) (xy 0 1.27) (xy -1.016 1.905) (xy 0 2.54) (xy 1.016 1.905) (xy 0 1.27)) '
        '(stroke (width 0) (type default)) (fill (type none)))) '
        '(symbol "PWR_FLAG_1_1" '
        f'{pin_expr(1, "pwr", 0, 0, 90, 0, "power_out")}) (embedded_fonts no))')


# Diode pin NUMBERS follow KiCad's Diode_THT footprints: pad 1 = cathode (K), pad 2 = anode (A); the pin NAMES stay A / K.
def define_zener():
    lib_symbols.append(
        '(symbol "D_Zener" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "D", False)} {lib_prop("Value", "D", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "D_Zener_0_1" '
        '(polyline (pts (xy -1.27 1.27) (xy -1.27 -1.27) (xy 1.27 0) (xy -1.27 1.27)) '
        '(stroke (width 0.254) (type default)) (fill (type none))) '
        '(polyline (pts (xy 0.762 1.27) (xy 1.27 1.27) (xy 1.27 -1.27) (xy 1.778 -1.27)) '
        '(stroke (width 0.254) (type default)) (fill (type none)))) '
        '(symbol "D_Zener_1_1" '
        f'{pin_expr("2", "A", -3.81, 0, 0, 2.54)} '
        f'{pin_expr("1", "K", 3.81, 0, 180, 2.54)}) (embedded_fonts no))')


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
        f'{pin_expr("2", "A", -3.81, 0, 0, 2.54)} '
        f'{pin_expr("1", "K", 3.81, 0, 180, 2.54)}) (embedded_fonts no))')


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


def instance(lib_id, ref, value, x, y, pin_numbers, ref_pos, val_pos, footprint="", bom=True, dnp=False):
    pins = " ".join(f'(pin "{q(str(p))}" (uuid "{u()}"))' for p in pin_numbers)
    items.append(
        f'(symbol (lib_id "{lib_id}") (at {n(x)} {n(y)} 0) (unit 1) '
        f'(exclude_from_sim no) (in_bom {"yes" if bom else "no"}) (on_board {"yes" if bom else "no"}) (dnp {"yes" if dnp else "no"}) (uuid "{u()}") '
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
             [t[0] for t in left + right],
             (x - width / 2, y - top - 3.81), (x - width / 2, y - top - 1.27), footprint)
    for lst, px, d in ((left, x - width / 2 - STUB, "left"), (right, x + width / 2 + STUB, "right")):
        for i, t in enumerate(lst):
            net = t[2]
            if net:
                stub_label(net, px, y - ((rows - 1) * 1.27 - i * 2.54), d)
    return ref


def header(title, x, y, pins, ref_prefix="J", footprint=None):
    """pins: [(name, net)] -> one 1xN 0.1in header, pin numbers 1..N."""
    cnt = len(pins)
    names = "".join(c if c.isalnum() else "p" for c in "_".join(nm for nm, _ in pins))
    return block(f"Header1x{cnt:02d}_{names}", title, x, y,
                 left=[(i + 1, name, net) for i, (name, net) in enumerate(pins)], right=[],
                 ref_prefix=ref_prefix, width=15.24, footprint=footprint or FP_HDR.format(n=cnt))


def resistor(x, y, value):
    ref = next_ref("R")
    instance("HastaDAQ:R", ref, value, x, y, [1, 2],
             (x + 2.54, y - 1.27), (x + 2.54, y + 2.54), "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P7.62mm_Horizontal")
    return (x, y - 3.81), (x, y + 3.81)  # pin1 (top), pin2 (bottom)


def vertical_part(libname, prefix, value, x, y, top_net, bot_net, footprint, dnp=False):
    """Vertical 2-pin part whose pins connect to net labels at the top/bottom."""
    x, y = snap(x), snap(y)
    ref = next_ref(prefix)
    instance(f"HastaDAQ:{libname}", ref, value, x, y, [1, 2],
             (x + 3.81, y - 1.27), (x + 3.81, y + 2.54), footprint, dnp=dnp)
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



def define_inductor():
    """Axial ferrite bead / inductor: a filled box with two vertical pins (like the resistor body)."""
    lib_symbols.append(
        '(symbol "Ferrite" (pin_numbers (hide yes)) (pin_names (offset 0)) '
        '(exclude_from_sim no) (in_bom yes) (on_board yes) '
        f'{lib_prop("Reference", "L", False)} {lib_prop("Value", "Ferrite", False)} '
        f'{lib_prop("Footprint", "")} {lib_prop("Datasheet", "")} '
        '(symbol "Ferrite_0_1" (rectangle (start -1.016 -2.54) (end 1.016 2.54) '
        '(stroke (width 0.254) (type default)) (fill (type outline)))) '
        '(symbol "Ferrite_1_1" '
        f'{pin_expr(1, "", 0, 3.81, 270, 1.27)} '
        f'{pin_expr(2, "", 0, -3.81, 90, 1.27)}) (embedded_fonts no))')


# ----------------------------------------------------------------- per-project setup / output
def init(project, out_dir, title, paper="A2"):
    """Start a new schematic. Mutates the shared containers in place so callers that did
    `from schgen_common import *` keep seeing the same objects."""
    global PROJECT, OUT_DIR, ROOT_UUID, TITLE, PAPER
    PROJECT, OUT_DIR, TITLE, PAPER = project, pathlib.Path(out_dir), title, paper
    ROOT_UUID = str(uuid.uuid4())
    lib_symbols.clear()
    items.clear()
    ref_counters.clear()
    defined_blocks.clear()


def write_outputs(fp_lib_uri, rev="A"):
    """Write <project>.kicad_sch, the project symbol library, both library tables and (if missing)
    the .kicad_pro. fp_lib_uri is where the project's HastaDAQ footprint library lives, e.g.
    "${KIPRJMOD}/HastaDAQ.pretty"."""
    embedded = [s.replace('(symbol "', '(symbol "HastaDAQ:', 1) for s in lib_symbols]
    sch = (
        f'(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0") '
        f'(uuid "{ROOT_UUID}") (paper "{PAPER}") '
        f'(title_block (title "{TITLE}") (rev "{rev}") (company "HastaArduino")) '
        f'(lib_symbols {" ".join(embedded)}) '
        + " ".join(items) +
        ' (sheet_instances (path "/" (page "1"))) (embedded_fonts no))'
    )
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / f"{PROJECT}.kicad_sch").write_text(sch, encoding="utf-8")
    (OUT_DIR / "HastaDAQ.kicad_sym").write_text(
        '(kicad_symbol_lib (version 20241209) (generator "kicad_symbol_editor") '
        '(generator_version "9.0") ' + " ".join(lib_symbols) + ")", encoding="utf-8")
    (OUT_DIR / "fp-lib-table").write_text(
        '(fp_lib_table\n  (version 7)\n'
        f'  (lib (name "HastaDAQ")(type "KiCad")(uri "{fp_lib_uri}")(options "")(descr "HastaDAQ custom footprints"))\n)\n',
        encoding="utf-8")
    (OUT_DIR / "sym-lib-table").write_text(
        '(sym_lib_table\n  (version 7)\n'
        '  (lib (name "HastaDAQ")(type "KiCad")(uri "${KIPRJMOD}/HastaDAQ.kicad_sym")(options "")(descr "HastaDAQ rig modules"))\n)\n',
        encoding="utf-8")
    pro = OUT_DIR / f"{PROJECT}.kicad_pro"
    if not pro.exists():
        pro.write_text('{\n  "meta": {\n    "filename": "' + PROJECT + '.kicad_pro",\n    "version": 3\n  }\n}\n',
                       encoding="utf-8")
    print("wrote", OUT_DIR / f"{PROJECT}.kicad_sch")
