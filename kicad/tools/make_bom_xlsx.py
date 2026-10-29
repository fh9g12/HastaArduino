"""Build the purchasing BOM workbook (docs/BOM_rev-a.xlsx) from the two rev-a schematics.

    python make_bom_xlsx.py [out.xlsx] [--force]

Reads the schematics' BOM with kicad-cli (reference, value, footprint, quantity), maps every reference to a purchasable
item (ITEMS below holds the supplier, RS stock number and notes, taken from docs/PARTS_TO_SELECT.md), and writes a workbook
the owner marks up while buying. REFUSES to overwrite an existing workbook unless --force, because the owner's ticks, quantities
and prices live in it. Needs openpyxl (the Python 3.13 install has it); kicad-cli is found like in export_fab.py.
"""
import csv
import pathlib
import shutil
import subprocess
import sys
import tempfile

from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

ROOT = pathlib.Path(__file__).resolve().parents[2]
REL = ROOT / "kicad" / "releases" / "rev-a"
RS = "RS Components"

# key: (group, item, spec, supplier, supplier part no., notes)  -- order here is the order on the shopping list
ITEMS = {
    # ---- main board modules
    "pico": ("Main board modules", "Pimoroni Pico Plus 2", "RP2350, 16 MB flash, 8 MB PSRAM, USB-C", "Pimoroni", "",
             "Footprint is the 'header pins' version: check the one you buy has headers (or add 2 x 1x20 pin headers). Soldered straight to the PCB."),
    "pololu": ("Main board modules", "Pololu D42V55F8 step-down regulator", "8.4 V, 5 A (servo rail), 6.1 mm tall", "Pololu", "", ""),
    "babybuck": ("Main board modules", "SparkFun BabyBuck 5V (AP63357)", "5 V buck for Pico VSYS and Orbis", "SparkFun", "", "EN may be left open."),
    "fod817": ("Main board semiconductors", "onsemi FOD817A opto-coupler", "4-pin DIP, CTR 80-160 %", RS, "761-4439", "TRIG_IN stage."),
    "q2n3904": ("Main board semiconductors", "2N3904 NPN transistor", "TO-92 (pin 1 E, 2 B, 3 C)", RS, "", "RS number not recorded in the docs: add it when you find it."),
    "d1": ("Main board semiconductors", "STMicroelectronics 1N5822 Schottky diode", "3 A, 40 V, DO-201AD", RS, "687-0877", "Supply reverse-protection diode."),
    "zener": ("Main board semiconductors", "Taiwan Semi BZX55C5V1 zener diode", "5.1 V, 500 mW, DO-35", RS, "748-5051", "D2 soft-stop clamp, D4 SBUS IN clamp."),
    "bav": ("Main board semiconductors", "Vishay BAV17-BAV21 switching diode", "DO-35, 250 mA (any family member)", RS, "700-3863",
            "Schematic text says 1N4148; any DO-35 small-signal diode works (1N4148 etc.). Confirm the exact type on the RS page."),
    # ---- main board capacitors
    "c_eca": ("Main board capacitors", "Panasonic ECA1EM101 electrolytic 100 uF 25 V", "6.3 x 11.2 mm, 2.5 mm pitch, 85 C", RS, "075-9069", "C1, 12 V input bulk."),
    "c_eeu": ("Main board capacitors", "Panasonic EEUFR1C471 electrolytic 470 uF 16 V", "8.0 x 11.5 mm, 3.5 mm pitch, low ESR, 105 C", RS, "708-3620", "C2, servo rail bulk."),
    "c_lhk100": ("Main board capacitors", "RS PRO LHK electrolytic 100 uF 10 V", "5 x 7 mm, 2.0 mm pitch, 105 C", RS, "707-5799", "C3, 5 V bulk near the Pico."),
    # ---- resistors (both boards)
    "r10k": ("Resistors (1/4 W axial, DIN0207)", "Resistor 10 k", "Yageo MFR-25FTE52-10K, metal film, 1 %, 1/4 W axial, 6.3 x 2.4 mm body", RS, "199-7658", "Sold as a tape of 100 (about 1.80 GBP ex VAT). Main R14 is left unfitted at first (SBUS IN pull-down) but included here."),
    "r1k": ("Resistors (1/4 W axial, DIN0207)", "Resistor 1 k", "1/4 W axial", RS, "", ""),
    "r2k2": ("Resistors (1/4 W axial, DIN0207)", "Resistor 2.2 k", "1/4 W axial", RS, "", "Q1 base resistor."),
    "r1k5": ("Resistors (1/4 W axial, DIN0207)", "Resistor 1.5 k", "1/4 W axial", RS, "", "TRIG_OUT pull-up."),
    "r1k1w": ("Resistors (1/4 W axial, DIN0207)", "Resistor 1 k, 1 W", "1 W axial, body about 9.9 x 3.6 mm", RS, "", "R8: 1 W because a 24 V trigger gives about 0.6 W."),
    "r0": ("Resistors (1/4 W axial, DIN0207)", "Resistor 0 ohm link", "1/4 W axial", RS, "", "Gauge board input-filter positions."),
    "r350": ("Resistors (1/4 W axial, DIN0207)", "Resistor 350 ohm precision", "1/4 W axial", "Own stock", "", "Gauge board completion pair: the owner's own precision parts."),
    # ---- connectors
    "h1x3": ("Pin headers (0.1 in, vertical)", "Pin header 1x3", "2.54 mm", "", "", "Main J10 (SBUS IN)."),
    "h1x4": ("Pin headers (0.1 in, vertical)", "Pin header 1x4", "2.54 mm", "", "", "Main J1 IMU, J2 loom, J6/J11 SSI; gauge J1/J2 loom."),
    "h1x5": ("Pin headers (0.1 in, vertical)", "Pin header 1x5", "2.54 mm", "", "", "Main J9 (TRIG_OUT pull-up select)."),
    "h2x3": ("Pin headers (0.1 in, vertical)", "Pin header 2x3", "2.54 mm", "", "", "Gauge J3/J4 half-bridge headers."),
    "h2x4": ("Pin headers (0.1 in, vertical)", "Pin header 2x4", "2.54 mm", "", "", "Main J3-J5 encoder ports, J8 supply."),
    "h3x6": ("Pin headers (0.1 in, vertical)", "Pin header 3x6 (3 rows of 6)", "2.54 mm, 18 pins", "", "", "Main J7, the six servo plugs. Make from three 1x6 strips, or snap from a long strip."),
    # ---- gauge board
    "mcp1700": ("Gauge board parts", "Microchip MCP1700-3302E/TO LDO", "3.3 V, 250 mA, TO-92", RS, "040-3888", "Input max 6.0 V: only the 5 V loom may feed it."),
    "c_47": ("Gauge board parts", "RS PRO LHK electrolytic 47 uF 16 V", "5 x 7 mm, 2.0 mm pitch", RS, "707-5758", "C1, polarised: + to +5V."),
    "c_10tan": ("Gauge board parts", "RS PRO CB solid tantalum 10 uF 10 V", "about 5.0 x 8.0 mm, 2.5 mm pitch", RS, "181-4731", "C3, polarised: + (bar) to +3V3."),
    "c_100n": ("Gauge board parts", "Vishay K-series ceramic capacitor 100 nF 50 V X7R", "radial, 2.5 mm lead spacing", RS, "181-6552", "C2, C4 fitted; C5, C6 are optional filter positions (DNP by default) but included."),
    "ads": ("Gauge board parts", "Adafruit ADS122C04 breakout", "24-bit I2C ADC, soldered straight to the PCB", "Adafruit", "", "Two per gauge board."),
    # ---- off-board
    "rm2": ("Off-board items", "Pimoroni RM2 WiFi breakout + JST-SH 8-pin lead", "cabled to the Pico Plus 2 SP/CE connector", "Pimoroni", "", "Not on either PCB."),
    "imu": ("Off-board items", "Adafruit ICM20649 IMU + Pi Hut Qwiic breakout 106676", "plugs into main J1", "Adafruit / The Pi Hut", "", "Not on either PCB."),
    "mt6835": ("Off-board items", "MT6835 encoder breakout", "SPI, 21-bit", "", "", "Main J3/J4 (ENC1, ENC2). Mark Own stock if you have them."),
    "orbis": ("Off-board items", "RLS Orbis encoder", "SPI", "RLS", "", "Main J5 (ENC3)."),
    "rm08": ("Off-board items", "RLS RM08 encoder (RM08SC0012B50U2G00, 3.3 V)", "12-bit SSI", "RLS", "", "Main J6/J11 (SSI1, SSI2)."),
    "ldb02": ("Off-board items", "RLS LDB02 line-drive board for SSI", "fitted inline near the Pico", "RLS", "", "One per RM08."),
    "servo": ("Off-board items", "Servos (up to 6) with SBUS", "plug into J7", "", "", "Quantity is the owner's rig; set Own stock if already owned."),
    "sbusrx": ("Off-board items", "SBUS receiver (Futaba R3008SB)", "4.8-7.4 V, for J10 pass-through", "", "", "Optional until the pass-through firmware exists."),
    # ---- assembly
    "jumper": ("Assembly items", "Shunt jumper 2.54 mm", "for J9", "", "", "One on J9."),
    "plugs": ("Assembly items", "Mating plugs and cable for the headers", "keyed or shrouded: owner's choice", "", "", "A rotated encoder or supply plug puts 5 V or 12 V on a wrong pin, so key them. Encoder and supply cables, loom plugs and wire, servo plugs, SBUS IN lead."),
    "ferrite": ("Assembly items", "Ferrite (clip-on or bead) for the +5V loom wire", "", "", "", "Not on either PCB."),
    "gaugecable": ("Assembly items", "Shielded twisted-pair gauge cable", "shield to GND at the gauge board only", "", "", ""),
    "m3": ("Assembly items", "M3 standoffs and screws (4 per board)", "one set per populated board", "", "", "Four M3 holes on each board."),
    "supply": ("Assembly items", "12 V supply lead for J8", "no fuse on the board: set the bench current limit (about 3 A)", "", "", ""),
}

# schematic reference -> item key (None = nothing to buy, e.g. copper test pads)
MAIN = {"U1": "pico", "U2": "pololu", "U3": "babybuck", "U4": "fod817", "Q1": "q2n3904", "D1": "d1", "D2": "zener", "D4": "zener",
        "D3": "bav", "C1": "c_eca", "C2": "c_eeu", "C3": "c_lhk100",
        "R1": "r10k", "R2": "r10k", "R3": "r10k", "R4": "r10k", "R6": "r10k", "R7": "r10k", "R9": "r10k", "R11": "r10k",
        "R14": "r10k", "R15": "r10k", "R5": "r1k", "R13": "r1k", "R10": "r2k2", "R12": "r1k5", "R8": "r1k1w",
        "J1": "h1x4", "J2": "h1x4", "J6": "h1x4", "J11": "h1x4", "J3": "h2x4", "J4": "h2x4", "J5": "h2x4", "J8": "h2x4",
        "J7": "h3x6", "J9": "h1x5", "J10": "h1x3", "TP1": None, "TP2": None}
GAUGE = {"U1": "mcp1700", "U2": "ads", "U3": "ads", "C1": "c_47", "C3": "c_10tan", "C2": "c_100n", "C4": "c_100n",
         "C5": "c_100n", "C6": "c_100n", "R1": "r0", "R2": "r0", "R3": "r0", "R4": "r0", "R5": "r350", "R6": "r350",
         "J1": "h1x4", "J2": "h1x4", "J3": "h2x3", "J4": "h2x3", "TP1": None, "TP2": None}
DNP_NOTE = {("Main", "R14"): "DNP at first", ("Gauge", "C5"): "DNP by default", ("Gauge", "C6"): "DNP by default"}
# fixed quantities not tied to a schematic reference: key -> (Excel formula for "Other qty", note on how derived)
OTHER = {"rm2": "1", "imu": "1", "mt6835": "2", "orbis": "1", "rm08": "2", "ldb02": "2", "servo": "6", "sbusrx": "1",
         "jumper": "1", "plugs": "", "ferrite": "1", "gaugecable": "", "m3": "=4*$C$4+4*$C$5", "supply": "1"}

FONT = "Arial"
F_BASE = Font(name=FONT, size=10)
F_BOLD = Font(name=FONT, size=10, bold=True)
F_HEAD = Font(name=FONT, size=10, bold=True, color="FFFFFF")
F_TITLE = Font(name=FONT, size=14, bold=True)
F_INPUT = Font(name=FONT, size=10, color="0000FF")
FILL_HEAD = PatternFill("solid", fgColor="305496")
FILL_GROUP = PatternFill("solid", fgColor="D9E1F2")
FILL_FILL = PatternFill("solid", fgColor="FFF2CC")
THIN = Side(style="thin", color="BFBFBF")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def find_kicad_cli():
    exe = shutil.which("kicad-cli")
    if exe:
        return exe
    for root in (pathlib.Path.home() / "AppData/Local/Programs/KiCad", pathlib.Path("C:/Program Files/KiCad")):
        for cand in sorted(root.glob("*/bin/kicad-cli.exe"), reverse=True):
            return str(cand)
    sys.exit("kicad-cli not found")


def read_bom(board):
    tmp = pathlib.Path(tempfile.mkdtemp()) / (board + ".csv")
    sch = REL / board / (board + ".kicad_sch")
    subprocess.run([find_kicad_cli(), "sch", "export", "bom", "--fields", "Reference,Value,Footprint,${QUANTITY}",
                    "--labels", "Refs,Value,Footprint,Qty", "--group-by", "Value,Footprint", "--ref-range-delimiter", "",
                    "-o", str(tmp), str(sch)], check=True, capture_output=True)
    with open(tmp, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def style_header(ws, row, ncols):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.font, cell.fill, cell.border = F_HEAD, FILL_HEAD, BORDER
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = pathlib.Path(args[0]) if args else ROOT / "docs" / "BOM_rev-a.xlsx"
    if out.exists() and "--force" not in sys.argv:
        sys.exit("%s exists (it holds your purchase marks); use --force to overwrite it" % out)

    # ------------------------------------------------------------ Board BOM rows from the schematics
    bom_rows = []
    for board, mapping, label in (("hastadaq", MAIN, "Main"), ("gaugeboard", GAUGE, "Gauge")):
        for row in read_bom(board):
            refs = [r for r in row["Refs"].replace(" ", "").split(",") if r]
            keys = {mapping[r] for r in refs}
            if len(keys) != 1:
                sys.exit("%s %s maps to several items: %s" % (label, row["Refs"], keys))
            key = keys.pop()
            note = "; ".join(DNP_NOTE[(label, r)] for r in refs if (label, r) in DNP_NOTE)
            bom_rows.append((label, ",".join(refs), int(row["Qty"]), row["Value"], row["Footprint"].split(":")[-1], key, note))
    names = [v[1] for v in ITEMS.values()]
    assert len(names) == len(set(names)), "item names must be unique (SUMIFS matches on them)"
    missing = [k for k in (set(MAIN.values()) | set(GAUGE.values())) if k and k not in ITEMS]
    if missing:
        sys.exit("items missing metadata: %s" % missing)

    wb = Workbook()
    shop = wb.active
    shop.title = "Shopping list"
    bomws = wb.create_sheet("Board BOM")

    # ------------------------------------------------------------ Board BOM sheet
    bomws["A1"], bomws["A1"].font = "Board BOM: every line of both schematics (rev A), from kicad-cli", F_TITLE
    bomws["A2"] = "Buy? = No means nothing to purchase (copper test pads). The Shopping list sums these quantities per item."
    bomws["A2"].font = F_BASE
    heads = ["Board", "References", "Qty", "Schematic value", "Footprint", "Buy?", "Shopping list item", "Note"]
    for c, h in enumerate(heads, 1):
        bomws.cell(row=4, column=c, value=h)
    style_header(bomws, 4, len(heads))
    b0 = 5
    for i, (label, refs, qty, value, fp, key, note) in enumerate(bom_rows):
        r = b0 + i
        vals = [label, refs, qty, value, fp, "Yes" if key else "No", ITEMS[key][1] if key else "(not purchased: copper pad)", note]
        for c, v in enumerate(vals, 1):
            cell = bomws.cell(row=r, column=c, value=v)
            cell.font, cell.border = F_BASE, BORDER
            cell.alignment = Alignment(vertical="top", wrap_text=c in (2, 4, 5, 8))
    b1 = b0 + len(bom_rows) - 1
    for col, w in zip("ABCDEFGH", (8, 22, 6, 52, 44, 7, 52, 22)):
        bomws.column_dimensions[col].width = w
    bomws.freeze_panes = "A5"
    bomws.auto_filter.ref = "A4:H%d" % b1

    # ------------------------------------------------------------ Shopping list sheet
    shop["A1"], shop["A1"].font = "Parts to buy: HastaDAQ main board + gauge board, rev A", F_TITLE
    legend = [
        "How to use: pick a Status in column A (dropdown), type what you bought in 'Qty bought' and the unit price; everything marked yellow is yours to fill in.",
        "Qty per board comes from the 'Board BOM' sheet; 'Qty needed' = main x boards + gauge x boards + other. Change the two board counts below (blue).",
        "Status 'Own stock' counts as done. Supplier part numbers are RS stock numbers where they are known (from docs/PARTS_TO_SELECT.md); blank means not found yet.",
    ]
    for i, t in enumerate(legend):
        shop.cell(row=2 + i, column=1, value=t).font = Font(name=FONT, size=9, italic=True)
    shop["B4"], shop["B4"].font = "Main boards to populate", F_BOLD
    shop["B5"], shop["B5"].font = "Gauge boards to populate", F_BOLD
    for r in (4, 5):
        c = shop.cell(row=r, column=3, value=1)
        c.font, c.fill, c.border = F_INPUT, FILL_FILL, BORDER
        c.comment = Comment("Assumed 1 of each. Change to how many boards you will actually build.", "BOM")
    heads = ["Status", "Group", "Item", "Spec / value", "Supplier", "Supplier part no. (RS stock no.)", "Qty per main board",
             "Qty per gauge board", "Other qty (off-board / assembly)", "Qty needed", "Qty bought", "Still to buy",
             "Unit price (GBP)", "Line cost (GBP)", "Order ref / date", "Used on", "Notes"]
    hr = 11
    for c, h in enumerate(heads, 1):
        shop.cell(row=hr, column=c, value=h)
    style_header(shop, hr, len(heads))
    shop.row_dimensions[hr].height = 42

    used = {}
    for label, refs, qty, value, fp, key, note in bom_rows:
        if key:
            used.setdefault(key, []).append("%s %s" % (label, refs))
    r = hr + 1
    first = r
    last_group = None
    item_rows = {}
    keys = [k for k in ITEMS if k in used or k in OTHER]
    for key in keys:
        group, item, spec, supplier, partno, notes = ITEMS[key]
        if group != last_group:
            for c in range(1, len(heads) + 1):
                shop.cell(row=r, column=c).fill = FILL_GROUP
                shop.cell(row=r, column=c).border = BORDER
            shop.cell(row=r, column=2, value=group).font = F_BOLD
            r += 1
            last_group = group
        item_rows[key] = r
        vals = {1: "Not ordered", 2: group, 3: item, 4: spec, 5: supplier, 6: partno,
                7: "=SUMIFS('Board BOM'!$C$%d:$C$%d,'Board BOM'!$A$%d:$A$%d,\"Main\",'Board BOM'!$G$%d:$G$%d,$C%d,'Board BOM'!$F$%d:$F$%d,\"Yes\")" % ((b0, b1) * 3 + (r,) + (b0, b1)),
                8: "=SUMIFS('Board BOM'!$C$%d:$C$%d,'Board BOM'!$A$%d:$A$%d,\"Gauge\",'Board BOM'!$G$%d:$G$%d,$C%d,'Board BOM'!$F$%d:$F$%d,\"Yes\")" % ((b0, b1) * 3 + (r,) + (b0, b1)),
                9: ((OTHER[key] if OTHER[key].startswith("=") else int(OTHER[key])) if OTHER.get(key) else None),
                10: "=G%d*$C$4+H%d*$C$5+I%d" % (r, r, r),
                11: None, 12: "=MAX(J%d-K%d,0)" % (r, r), 13: None, 14: "=K%d*M%d" % (r, r), 15: None,
                16: "; ".join(used.get(key, [])), 17: notes}
        for c in range(1, len(heads) + 1):
            cell = shop.cell(row=r, column=c, value=vals.get(c))
            cell.font, cell.border = F_BASE, BORDER
            cell.alignment = Alignment(vertical="top", wrap_text=c in (3, 4, 16, 17))
        for c in (1, 9, 11, 13, 15):                                  # cells the owner edits
            cell = shop.cell(row=r, column=c)
            cell.fill = FILL_FILL
            cell.font = F_INPUT
        if key == "plugs" or key == "gaugecable":
            shop.cell(row=r, column=9).comment = Comment("Quantity depends on your cable lengths and plug choice: type it in.", "BOM")
        shop.cell(row=r, column=13).number_format = '"£"#,##0.00'
        shop.cell(row=r, column=14).number_format = '"£"#,##0.00;("£"#,##0.00);"-"'
        for c in (7, 8, 9, 10, 11, 12):
            shop.cell(row=r, column=c).number_format = '0;-0;"-"'
            shop.cell(row=r, column=c).alignment = Alignment(horizontal="center", vertical="top")
        r += 1
    last = r - 1

    # ------------------------------------------------------------ summary (rows 4-9, columns E-H)
    rng = lambda col: "$%s$%d:$%s$%d" % (col, first, col, last)
    summary = [
        ("Items to buy", '=COUNTIF(%s,"Not ordered")+COUNTIF(%s,"Ordered")+COUNTIF(%s,"Received")+COUNTIF(%s,"Own stock")' % ((rng("A"),) * 4)),
        ("Not ordered", '=COUNTIF(%s,"Not ordered")' % rng("A")),
        ("Ordered, not yet received", '=COUNTIF(%s,"Ordered")' % rng("A")),
        ("Received or own stock", '=COUNTIF(%s,"Received")+COUNTIF(%s,"Own stock")' % (rng("A"), rng("A"))),
    ]
    shop["E3"], shop["E3"].font = "Progress", F_BOLD
    for i, (lab, f) in enumerate(summary):
        shop.cell(row=4 + i, column=5, value=lab).font = F_BASE
        c = shop.cell(row=4 + i, column=6, value=f)
        c.font, c.border = F_BASE, BORDER
    shop.cell(row=8, column=5, value="Complete").font = F_BOLD
    c = shop.cell(row=8, column=6, value="=IF(F4=0,0,F7/F4)")
    c.font, c.number_format, c.border = F_BOLD, "0%", BORDER
    shop.cell(row=9, column=5, value="Total spent (GBP)").font = F_BOLD
    c = shop.cell(row=9, column=6, value="=SUM(N%d:N%d)" % (first, last))
    c.font, c.number_format, c.border = F_BOLD, '"£"#,##0.00', BORDER

    # ------------------------------------------------------------ validation, formatting, layout
    dv = DataValidation(type="list", formula1='"Not ordered,Ordered,Received,Own stock"', allow_blank=False)
    dv.error, dv.errorTitle = "Pick one of: Not ordered, Ordered, Received, Own stock", "Status"
    shop.add_data_validation(dv)
    dv.add("A%d:A%d" % (first, last))
    rowrng = "A%d:Q%d" % (first, last)
    shop.conditional_formatting.add(rowrng, FormulaRule(formula=['OR($A%d="Received",$A%d="Own stock")' % (first, first)],
                                                        fill=PatternFill("solid", bgColor="C6EFCE")))
    shop.conditional_formatting.add(rowrng, FormulaRule(formula=['$A%d="Ordered"' % first],
                                                        fill=PatternFill("solid", bgColor="FFEB9C")))
    shop.conditional_formatting.add("L%d:L%d" % (first, last), FormulaRule(formula=["AND($J%d>0,$L%d>0,$A%d=\"Not ordered\")" % (first, first, first)],
                                                                        font=Font(name=FONT, bold=True, color="C00000")))
    for col, w in zip("ABCDEFGHIJKLMNOPQ", (13, 26, 40, 40, 16, 16, 9, 9, 13, 9, 9, 9, 11, 11, 18, 30, 60)):
        shop.column_dimensions[col].width = w
    shop.freeze_panes = shop.cell(row=hr + 1, column=4)
    shop.auto_filter.ref = "A%d:Q%d" % (hr, last)
    shop.sheet_view.zoomScale = 90
    shop.page_setup.orientation = "landscape"
    shop.page_setup.fitToWidth = 1
    shop.page_setup.fitToHeight = 0
    shop.sheet_properties.pageSetUpPr.fitToPage = True
    wb.calculation.fullCalcOnLoad = True

    out.parent.mkdir(parents=True, exist_ok=True)
    wb.save(out)
    print("wrote", out, "| items:", len(keys), "| board BOM lines:", len(bom_rows))


if __name__ == "__main__":
    main()
