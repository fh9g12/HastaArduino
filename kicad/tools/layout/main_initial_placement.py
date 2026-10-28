"""MAIN BOARD: build hastadaq.kicad_pcb from hastadaq.net and place every part (placement only, no routing).

    python.exe main_initial_placement.py <release>/hastadaq [--force]

Placement for the owner to adjust by hand in KiCad. Refuses to overwrite an existing .kicad_pcb unless --force is
given: once the owner has edited the board, do not re-run it. Footprint paths are set to the schematic symbol UUIDs
so Tools > Update PCB from Schematic works.

Layout brief (owner, 2026-10-27, third go): about 62 mm wide; Pico top left; the 5 V supply (BabyBuck) and the 8.4 V
supply (Pololu) with their capacitors top right; encoders along the bottom left, I2C + supply cable in the middle,
SBUS (servo header J7 just below the 8.4 V supply, SBUS IN) on the right.
  * 12 small parts (the 10 k pull-ups / pull-downs and D3) are HIDDEN UNDER THE PICO, mounted from the BACK of the board
    (bottom side) and soldered on the front, so their lead ends are under the module: clip the leads flush, and solder them
    before the Pico goes on. This is a deliberate exception to "everything on the top face". They sit only in the half of
    the module nearest the USB-C end; the rear PICO_REAR_FREE mm under the module is kept free of any pad because the
    Pico Plus 2's SP/CE JST connector is on its underside (exact position not verified).
  * A 20 mm strip behind the Pico (REAR_ZONE) is kept clear of parts so the SP/CE plug can be pushed in and pulled out.
    It is drawn on the User.Comments layer.

Coordinates are mm with the board's top-left corner at (0, 0), x right, y down; every footprint's pad 1 is its origin.
Rotation 90 turns a part counter-clockwise on screen (a header's pins then run to the right, an axial part's pad 2
goes up), 270 clockwise. FIXED parts have explicit positions; HIDDEN parts go in a grid under the Pico; the rest in
REGIONS are shelf-packed (left to right, top to bottom) using each footprint's real courtyard so they cannot overlap,
and they steer clear of the M3 screw-head circles and the rear zone. A rotation of None lets the packer pick 0 or 90.
"""
import os
import sys
import pcbnew
from pcbnew import FromMM, ToMM, VECTOR2I

W, H = 62.0, 100.0          # board outline
HOLE_INSET = 4.0            # M3 hole centres from each edge
HOLE_KEEPOUT = 3.5          # keep parts this far from a hole centre (screw head 6.5 mm)
CORNER_R = 3.0
PACK_GAP = 0.5

PICO_X, PICO_Y = 10.3, 3.34                       # pad 1 of the Pico (left column x, top pin y)
PICO_REAR = PICO_Y + 49.8                         # module outline's rear (bottom) edge, 53.1
PICO_PIN_ROWS = (PICO_X, PICO_X + 17.78)          # x of the two pin columns
PICO_REAR_FREE = 15.0                             # no hidden-part pads in the rear 15 mm of the module
REAR_ZONE = (7.0, PICO_REAR + 0.1, 30.5, PICO_REAR + 20.1)   # x0, y0, x1, y1: 20 mm behind the Pico, kept clear

# ref: (x, y, rotation) -- pad 1 position
FIXED = {
    "U1": (PICO_X, PICO_Y, 0),
    # top right: Schottky (+5V -> VSYS) along the top, 5 V bulk, BabyBuck (pads on its right edge)
    "D1": (33.0, 3.9, 0), "C3": (36.0, 14.0, 90), "U3": (56.0, 17.7, 0),
    # Pololu below the BabyBuck (pads along the bottom of the module, VOUT left, VIN right), caps and servo header below
    "U2": (38.12, 45.4, 0), "C2": (34.0, 54.0, 0), "C1": (46.0, 54.0, 0), "J7": (43.5, 60.0, 0),
    # bottom row below the rear zone: SPI encoder headers on the left, then I2C (IMU, loom) and the supply cable
    "J3": (5.5, 75.8, 0), "J4": (12.5, 75.8, 0), "J5": (19.5, 75.8, 0),
    "J1": (30.5, 75.8, 0), "J2": (35.5, 75.8, 0), "J8": (40.0, 75.8, 0),
    # GND test points in the narrow strip left of the Pico (one by the Pico, one a little further down)
    "TP1": (5.6, 40.0, 0), "TP2": (5.6, 48.0, 0),
}

# Parts hidden under the Pico on the bottom side, in a grid of vertical slots between the two pin columns.
HIDDEN = ["R1", "R2", "R3", "R4", "R15", "R6", "R9", "R7", "R11", "R10", "R5", "D3"]
HIDDEN_COLS = [12.4, 16.0, 19.6, 24.0]            # slot centre x
HIDDEN_ROWS = [12.0, 22.6, 33.2]                  # slot centre y (each slot is about 10 mm tall)

# name: (x0, y0, x1, y1, [(ref, rotation or None), ...])  -- packed in this order, rows left to right
REGIONS = {
    # SSI headers lying down under the encoder headers; the strip below them holds R14 and D4 (clear of the screw hole)
    "ssi": (4.0, 88.0, 28.5, 91.9, [("J6", 90), ("J11", 90)]),
    "lowleft": (7.5, 92.6, 28.5, 97.5, [("R14", 0), ("D4", 0)]),
    "mid": (29.0, 88.0, 45.0, 97.5, [("U4", 0), ("Q1", 0)]),
    # SBUS IN header lying down beside C1, right under the 8.4 V supply and next to the servo header J7
    "sbus_in": (51.0, 49.8, 61.0, 58.0, [("J10", 90)]),
    "right": (45.4, 67.5, 58.3, 97.5, [("R8", None), ("J9", 0), ("R12", None), ("R13", None), ("D2", None)]),
}

folder = os.path.abspath(sys.argv[1])
force = "--force" in sys.argv
net_path = os.path.join(folder, "hastadaq.net")
pcb_path = os.path.join(folder, "hastadaq.kicad_pcb")
if os.path.exists(pcb_path) and not force:
    sys.exit("refusing to overwrite " + pcb_path)

KICAD_FP = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "KiCad", "10.0", "share", "kicad", "footprints")
LIBS = {"HastaDAQ": os.path.join(folder, "HastaDAQ.pretty")}


def libdir(nick):
    return LIBS.get(nick) or os.path.join(KICAD_FP, nick + ".pretty")


# ---- netlist parsing (same minimal s-expression reader as gauge_initial_placement.py) ----
def tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in "()":
            yield c
            i += 1
        elif c == '"':
            j = i + 1
            s = []
            while text[j] != '"':
                if text[j] == "\\":
                    j += 1
                s.append(text[j])
                j += 1
            yield ("s", "".join(s))
            i = j + 1
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "()":
                j += 1
            yield ("s", text[i:j])
            i = j


def parse(text):
    stack = [[]]
    for t in tokenize(text):
        if t == "(":
            stack.append([])
        elif t == ")":
            done = stack.pop()
            stack[-1].append(done)
        else:
            stack[-1].append(t[1])
    return stack[0][0]


def find_all(node, name):
    return [c for c in node if isinstance(c, list) and c and c[0] == name]


def find(node, name):
    r = find_all(node, name)
    return r[0] if r else None


tree = parse(open(net_path, encoding="utf-8").read())
comps = {}
for c in find_all(find(tree, "components"), "comp"):
    ref = find(c, "ref")[1]
    props = {p[1][1] for p in find_all(c, "property") if len(p) > 1 and isinstance(p[1], list)}
    comps[ref] = dict(value=find(c, "value")[1], fp=find(c, "footprint")[1],
                      uuid=find(c, "tstamps")[1], dnp="dnp" in props)
nets = {}
pin_net = {}
for n in find_all(find(tree, "nets"), "net"):
    name = find(n, "name")[1]
    nets[name] = []
    for node in find_all(n, "node"):
        k = (find(node, "ref")[1], find(node, "pin")[1])
        nets[name].append(k)
        pin_net[k] = name

packed_refs = [r for reg in REGIONS.values() for r, _ in reg[4]]
all_placed = list(FIXED) + HIDDEN + packed_refs
missing = sorted(set(comps) - set(all_placed))
extra = sorted(set(all_placed) - set(comps))
dup = sorted({r for r in all_placed if all_placed.count(r) > 1})
assert not missing and not extra and not dup, ("unplaced:", missing, "unknown:", extra, "twice:", dup)
assert len(HIDDEN) <= len(HIDDEN_COLS) * len(HIDDEN_ROWS), "more hidden parts than slots"

board = pcbnew.BOARD()
for name in nets:
    board.Add(pcbnew.NETINFO_ITEM(board, name))

fps = {}
for ref, c in comps.items():
    nick, fpname = c["fp"].split(":")
    fp = pcbnew.FootprintLoad(libdir(nick), fpname)
    assert fp is not None, c["fp"]
    fp.SetFPID(pcbnew.LIB_ID(nick, fpname))
    fp.SetReference(ref)
    fp.SetValue(c["value"])
    fp.SetPath(pcbnew.KIID_PATH("/" + c["uuid"]))
    if c["dnp"]:
        fp.SetDNP(True)
    for pad in fp.Pads():
        key = (ref, pad.GetNumber())
        if key in pin_net:
            pad.SetNet(board.FindNet(pin_net[key]))
    board.Add(fp)
    fps[ref] = fp


def courtyard(fp):
    """Courtyard (x0, y0, x1, y1) in mm relative to the footprint origin at rotation 0 (pads as a fallback)."""
    boxes = []
    for it in fp.GraphicalItems():
        if it.GetLayer() == pcbnew.F_CrtYd:
            b = it.GetBoundingBox()
            boxes.append((ToMM(b.GetLeft()), ToMM(b.GetTop()), ToMM(b.GetRight()), ToMM(b.GetBottom())))
    if not boxes:
        for p in fp.Pads():
            b = p.GetBoundingBox()
            boxes.append((ToMM(b.GetLeft()), ToMM(b.GetTop()), ToMM(b.GetRight()), ToMM(b.GetBottom())))
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def rotated(box, rot):
    """Courtyard box after rotating the part counter-clockwise by rot degrees about its origin (y down)."""
    x0, y0, x1, y1 = box
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    if rot % 360 == 90:
        pts = [(y, -x) for x, y in pts]
    elif rot % 360 == 180:
        pts = [(-x, -y) for x, y in pts]
    elif rot % 360 == 270:
        pts = [(-y, x) for x, y in pts]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def put(ref, x, y, rot):
    fp = fps[ref]
    fp.SetOrientationDegrees(rot)
    fp.SetPosition(VECTOR2I(FromMM(x), FromMM(y)))


for ref, (x, y, rot) in FIXED.items():
    put(ref, x, y, rot)


# ---- hidden parts: bottom side, centred (by their pads) in vertical slots under the Pico ----
def pad_box(fp):
    xs0, ys0, xs1, ys1 = [], [], [], []
    for p in fp.Pads():
        b = p.GetBoundingBox()
        xs0.append(ToMM(b.GetLeft())); ys0.append(ToMM(b.GetTop()))
        xs1.append(ToMM(b.GetRight())); ys1.append(ToMM(b.GetBottom()))
    return min(xs0), min(ys0), max(xs1), max(ys1)


slots = [(cx, cy) for cy in HIDDEN_ROWS for cx in HIDDEN_COLS]
for ref, (cx, cy) in zip(HIDDEN, slots):
    fp = fps[ref]
    fp.SetOrientationDegrees(90)
    fp.SetPosition(VECTOR2I(FromMM(cx), FromMM(cy)))
    fp.Flip(fp.GetPosition(), True)               # to the bottom side (mirrored left-right, as KiCad's flip does)
    x0, y0, x1, y1 = pad_box(fp)                  # re-centre by the pads so the slot grid is exact
    dx, dy = cx - (x0 + x1) / 2, cy - (y0 + y1) / 2
    p = fp.GetPosition()
    fp.SetPosition(VECTOR2I(p.x + FromMM(dx), p.y + FromMM(dy)))

HOLES = [(HOLE_INSET, HOLE_INSET), (W - HOLE_INSET, HOLE_INSET),
         (W - HOLE_INSET, H - HOLE_INSET), (HOLE_INSET, H - HOLE_INSET)]


def hits_hole(x0, y0, x1, y1):
    for hx, hy in HOLES:
        nx, ny = min(max(hx, x0), x1), min(max(hy, y0), y1)
        if (nx - hx) ** 2 + (ny - hy) ** 2 < HOLE_KEEPOUT ** 2:
            return True
    return False


def hits_rear_zone(x0, y0, x1, y1):
    zx0, zy0, zx1, zy1 = REAR_ZONE
    return x0 < zx1 and x1 > zx0 and y0 < zy1 and y1 > zy0


overflow = []
for name, (rx0, ry0, rx1, ry1, parts) in REGIONS.items():
    cx, cy, row_h = rx0, ry0, 0.0
    for ref, rot_spec in parts:
        base = courtyard(fps[ref])
        options = [0, 90] if rot_spec is None else [rot_spec]
        boxes = {r: rotated(base, r) for r in options}

        # pick the orientation that fits the current row with the least extra height, else the shorter one
        def cost(r):
            bx0, by0, bx1, by1 = boxes[r]
            w, h = bx1 - bx0, by1 - by0
            fits = cx + w <= rx1 + 1e-6
            return (0 if fits else 1, max(h - row_h, 0) if fits else h, w)

        rot = min(options, key=cost)
        bx0, by0, bx1, by1 = boxes[rot]
        w, h = bx1 - bx0, by1 - by0
        while True:
            if cx + w > rx1 + 1e-6:                      # next row
                cx, cy, row_h = rx0, cy + row_h + PACK_GAP, 0.0
                continue
            if cy + h > ry1 + 1e-6:
                overflow.append((name, ref))
                break
            if hits_hole(cx, cy, cx + w, cy + h) or hits_rear_zone(cx, cy, cx + w, cy + h):
                cx += 1.0                                # step past the screw-head circle / rear zone
                continue
            break
        put(ref, cx - bx0, cy - by0, rot)
        cx += w + PACK_GAP
        row_h = max(row_h, h)
if overflow:
    print("WARNING: did not fit in their region:", overflow)


# ---- outline with rounded corners and four M3 holes ----
def mm(x, y):
    return VECTOR2I(FromMM(x), FromMM(y))


def line(x1, y1, x2, y2, layer=pcbnew.Edge_Cuts, w=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(mm(x1, y1))
    s.SetEnd(mm(x2, y2))
    s.SetLayer(layer)
    s.SetWidth(FromMM(w))
    board.Add(s)


def arc(cx, cy, sx, sy):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_ARC)
    s.SetCenter(mm(cx, cy))
    s.SetStart(mm(sx, sy))
    s.SetArcAngleAndEnd(pcbnew.EDA_ANGLE(90, pcbnew.DEGREES_T))
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(FromMM(0.1))
    board.Add(s)


r = CORNER_R
line(r, 0, W - r, 0)
line(W, r, W, H - r)
line(W - r, H, r, H)
line(0, H - r, 0, r)
arc(r, r, 0, r)
arc(W - r, r, W - r, 0)
arc(W - r, H - r, W, H - r)
arc(r, H - r, r, H)

for i, (hx, hy) in enumerate(HOLES, 1):
    fp = pcbnew.FootprintLoad(os.path.join(KICAD_FP, "MountingHole.pretty"), "MountingHole_3.2mm_M3")
    fp.SetFPID(pcbnew.LIB_ID("MountingHole", "MountingHole_3.2mm_M3"))
    fp.SetReference("H%d" % i)
    fp.SetBoardOnly(True)
    fp.Reference().SetVisible(False)
    fp.SetPosition(mm(hx, hy))
    board.Add(fp)
    c = pcbnew.PCB_SHAPE(board)               # 6.5 mm screw-head clearance, drawing layer only
    c.SetShape(pcbnew.SHAPE_T_CIRCLE)
    c.SetCenter(mm(hx, hy))
    c.SetEnd(mm(hx + 3.25, hy))
    c.SetLayer(pcbnew.Dwgs_User)
    c.SetWidth(FromMM(0.1))
    board.Add(c)

# the 20 mm SP/CE plug-clearance strip behind the Pico, and the rear part of the module where no hidden-part pad may go
for (x0, y0, x1, y1) in (REAR_ZONE, (PICO_PIN_ROWS[0] - 2.0, PICO_REAR - PICO_REAR_FREE,
                                     PICO_PIN_ROWS[1] + 2.0, PICO_REAR)):
    rect = pcbnew.PCB_SHAPE(board)
    rect.SetShape(pcbnew.SHAPE_T_RECT)
    rect.SetStart(mm(x0, y0))
    rect.SetEnd(mm(x1, y1))
    rect.SetLayer(pcbnew.Cmts_User)
    rect.SetWidth(FromMM(0.15))
    rect.SetFilled(False)
    board.Add(rect)
tx = pcbnew.PCB_TEXT(board)
tx.SetText("SP/CE plug clearance (20 mm): keep clear")
tx.SetPosition(mm((REAR_ZONE[0] + REAR_ZONE[2]) / 2, (REAR_ZONE[1] + REAR_ZONE[3]) / 2))
tx.SetLayer(pcbnew.Cmts_User)
tx.SetTextSize(VECTOR2I(FromMM(1.0), FromMM(1.0)))
board.Add(tx)

pcbnew.SaveBoard(pcb_path, board)
print("wrote", pcb_path, "| footprints:", len(comps), "+ 4 holes | board %.0f x %.0f mm" % (W, H))
