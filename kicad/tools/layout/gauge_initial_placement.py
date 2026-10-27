"""GAUGE BOARD, HISTORICAL: first-draft board creation and placement. Do not re-run over a board you are editing.

    python.exe gauge_initial_placement.py <gaugeboard folder> [--force]

Builds gaugeboard.kicad_pcb from gaugeboard.net (footprints loaded from the KiCad and HastaDAQ libraries, each
footprint path set to its schematic symbol UUID so Tools > Update PCB from Schematic works), then places the parts,
draws a rounded outline and four M3 holes. It reflects the FIRST layout idea (analog rows facing, point-symmetric).
The owner then rearranged the board by hand in KiCad, so the as-built placement is NOT what this script produces.
Useful as a template for the net/footprint loading and the place_pair helper on the next board. Refuses to
overwrite an existing .kicad_pcb unless --force is given.
"""
import os
import sys
import pcbnew
from pcbnew import FromMM, VECTOR2I

W, H = 60.0, 70.0           # board outline, mm
HOLE_INSET = 4.0            # M3 hole centres from each edge
CORNER_R = 3.0

folder = os.path.abspath(sys.argv[1])
force = "--force" in sys.argv
net_path = os.path.join(folder, "gaugeboard.net")
pcb_path = os.path.join(folder, "gaugeboard.kicad_pcb")
if os.path.exists(pcb_path) and not force:
    sys.exit("refusing to overwrite " + pcb_path)

KICAD_FP = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "KiCad", "10.0",
                        "share", "kicad", "footprints")
LIBS = {"HastaDAQ": os.path.join(folder, "..", "hastadaq", "HastaDAQ.pretty")}


def libdir(nick):
    return LIBS.get(nick) or os.path.join(KICAD_FP, nick + ".pretty")


# ---- netlist parsing -------------------------------------------------------
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
    props = {p[1][1]: (p[2][1] if len(p) > 2 else "") for p in find_all(c, "property")
             if len(p) > 1 and isinstance(p[1], list)}
    comps[ref] = dict(
        ref=ref,
        value=find(c, "value")[1],
        fp=find(c, "footprint")[1],
        uuid=find(c, "tstamps")[1],
        dnp="dnp" in props,
    )
nets = {}   # name -> [(ref, pin)]
pin_net = {}  # (ref, pin) -> net name
for n in find_all(find(tree, "nets"), "net"):
    name = find(n, "name")[1]
    nets[name] = []
    for node in find_all(n, "node"):
        k = (find(node, "ref")[1], find(node, "pin")[1])
        nets[name].append(k)
        pin_net[k] = name

# ---- board -----------------------------------------------------------------
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


def mm(x, y):
    return VECTOR2I(FromMM(x), FromMM(y))


def padpos(fp, num):
    for p in fp.Pads():
        if p.GetNumber() == str(num):
            return p.GetPosition()
    raise KeyError(num)


def place_origin(ref, x, y, angle=0):
    """Put the footprint origin (pin/pad 1 for everything here) at x, y."""
    fp = fps[ref]
    fp.SetOrientationDegrees(angle)
    fp.SetPosition(mm(x, y))


def place_pair(ref, anchor_net, x, y, direction):
    """Two-pad part: the pad on `anchor_net` goes at x, y and the other pad lies in `direction`."""
    fp = fps[ref]
    pads = [p for p in fp.Pads() if p.GetNumber() in ("1", "2")]
    assert len(pads) == 2, ref
    anchor = [p for p in pads if pin_net.get((ref, p.GetNumber())) == anchor_net]
    assert anchor, "%s has no pad on %s: %s" % (ref, anchor_net,
                                                [pin_net.get((ref, p.GetNumber())) for p in pads])
    ap = anchor[0]
    other = [p for p in pads if p is not ap][0]
    want = {"right": (1, 0), "left": (-1, 0), "down": (0, 1), "up": (0, -1)}[direction]
    for ang in (0, 90, 180, 270):
        fp.SetOrientationDegrees(ang)
        fp.SetPosition(mm(0, 0))
        a, o = ap.GetPosition(), other.GetPosition()
        dx, dy = o.x - a.x, o.y - a.y
        if (dx * want[0] > 0 and abs(dy) < 1000) or (dy * want[1] > 0 and abs(dx) < 1000):
            a = ap.GetPosition()
            fp.SetPosition(VECTOR2I(FromMM(x) - a.x, FromMM(y) - a.y))
            return
    raise RuntimeError(ref)


N = lambda s: "/" + s

# Modules face each other: U2 rotated 180 (digital row on top, analog row facing down), U3 not rotated (analog row
# facing up, digital row at the bottom). Point-symmetric about (CX, CY); R5/R6 sit on that centre point.
CX, CY, HH = 30.0, 35.0, 14.5
YA2, YA3 = CY - HH, CY + HH            # analog row y of U2 (upper) and U3 (lower)
place_origin("U2", CX + 6.35, YA2 - 12.7, 180)
place_origin("U3", CX - 6.35, YA3 + 12.7, 0)
for ref, ex, ey in (("U2", CX + 3.81, YA2), ("U3", CX - 3.81, YA3)):   # pad 7 = A0
    p = padpos(fps[ref], 7)
    assert abs(pcbnew.ToMM(p.x) - ex) < 0.01 and abs(pcbnew.ToMM(p.y) - ey) < 0.01, (ref, pcbnew.ToMM(p.x), pcbnew.ToMM(p.y))

# Loom headers J1, J2 (pin 1 at top), top left
place_origin("J1", 6.5, 10.0)
place_origin("J2", 11.58, 10.0)

# Power parts (left zone)
place_pair("C1", N("+5V"), 6.0, 24.0, "right")
place_pair("C2", N("+5V"), 12.0, 24.0, "right")
place_origin("U1", 8.0, 31.0)
place_pair("C3", N("+3V3"), 14.0, 31.0, "right")
place_pair("C4", N("+3V3"), 11.0, 36.0, "right")
place_origin("TP2", 4.5, 37.0)
place_origin("TP1", 4.5, 40.5)

# Channel 1: upper half of the band, J3 at the right (SIG row level with R1)
place_pair("C5", N("ADS1_A0"), CX + 3.81, YA2 + 5.0, "left")
place_pair("R1", N("ADS1_A0"), CX + 7.5, YA2 + 5.0, "right")
place_pair("R2", N("ADS1_A1"), CX + 1.27, YA2 + 8.6, "left")
place_origin("J3", 51.5, YA2 + 5.0 - 2.54)
# Channel 2: point image of channel 1, lower half of the band, J4 at the left (same orientation as J3)
place_pair("C6", N("ADS2_A0"), CX - 3.81, YA3 - 5.0, "right")
place_pair("R3", N("ADS2_A0"), CX - 7.5, YA3 - 5.0, "left")
place_pair("R4", N("ADS2_A1"), CX - 1.27, YA3 - 8.6, "right")
place_origin("J4", 8.5, YA3 - 5.0 - 2.54)

# Completion pair on the centre point: REF ends together, R5 (+3V3) toward the regulator, R6 (GND) away
place_pair("R5", N("ADS_REF"), CX, CY - 1.8, "left")
place_pair("R6", N("ADS_REF"), CX, CY + 1.8, "right")

# Reference text: upright
def ref_at(ref, x, y):
    t = fps[ref].Reference()
    t.SetTextAngleDegrees(0)
    t.SetPosition(mm(x, y))


ref_at("U2", CX, 3.2)
ref_at("U3", CX, 66.8)
ref_at("TP1", 4.5, 42.5)
ref_at("TP2", 4.5, 35.2)
ref_at("R5", 22.4, 35.4)
ref_at("R2", 21.0, 29.1)
ref_at("R4", 39.0, 40.9)
ref_at("R6", 41.2, 36.8)
ref_at("C5", CX - 2.5, YA2 + 5.0)
ref_at("C6", CX + 2.5, YA3 - 5.0)


# ---- outline, mounting holes -------------------------------------------------
def line(x1, y1, x2, y2, layer=pcbnew.Edge_Cuts, w=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(mm(x1, y1))
    s.SetEnd(mm(x2, y2))
    s.SetLayer(layer)
    s.SetWidth(FromMM(w))
    board.Add(s)


def arc(cx, cy, sx, sy, ang, layer=pcbnew.Edge_Cuts, w=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_ARC)
    s.SetCenter(mm(cx, cy))
    s.SetStart(mm(sx, sy))
    s.SetArcAngleAndEnd(pcbnew.EDA_ANGLE(ang, pcbnew.DEGREES_T))
    s.SetLayer(layer)
    s.SetWidth(FromMM(w))
    board.Add(s)


r = CORNER_R
line(r, 0, W - r, 0)
line(W, r, W, H - r)
line(W - r, H, r, H)
line(0, H - r, 0, r)
# corners, each arc sweeps 90 deg counter-clockwise starting from the given point
arc(r, r, 0, r, 90)                  # top-left: from (0,r) round to (r,0)
arc(W - r, r, W - r, 0, 90)          # top-right
arc(W - r, H - r, W, H - r, 90)      # bottom-right
arc(r, H - r, r, H, 90)              # bottom-left

mh_lib = os.path.join(KICAD_FP, "MountingHole.pretty")
for i, (hx, hy) in enumerate([(HOLE_INSET, HOLE_INSET), (W - HOLE_INSET, HOLE_INSET),
                              (W - HOLE_INSET, H - HOLE_INSET), (HOLE_INSET, H - HOLE_INSET)], 1):
    fp = pcbnew.FootprintLoad(mh_lib, "MountingHole_3.2mm_M3")
    fp.SetFPID(pcbnew.LIB_ID("MountingHole", "MountingHole_3.2mm_M3"))
    fp.SetReference("H%d" % i)
    fp.SetBoardOnly(True)
    fp.Reference().SetVisible(False)
    fp.SetPosition(mm(hx, hy))
    board.Add(fp)
    # screw-head clearance (6.5 mm) on a drawing layer, for reference
    c = pcbnew.PCB_SHAPE(board)
    c.SetShape(pcbnew.SHAPE_T_CIRCLE)
    c.SetCenter(mm(hx, hy))
    c.SetEnd(mm(hx + 3.25, hy))
    c.SetLayer(pcbnew.Dwgs_User)
    c.SetWidth(FromMM(0.1))
    board.Add(c)

pcbnew.SaveBoard(pcb_path, board)
print("wrote", pcb_path, "footprints:", len(list(board.GetFootprints())))
for ref in sorted(fps):
    p = fps[ref].GetPosition()
    print("%-4s %-9s at %.2f, %.2f  rot %g" % (ref, comps[ref]["fp"].split(":")[1][:9],
                                              pcbnew.ToMM(p.x), pcbnew.ToMM(p.y),
                                              fps[ref].GetOrientationDegrees()))
