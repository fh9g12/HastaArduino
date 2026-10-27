"""GAUGE BOARD, AS-RUN RECORD: the routing applied to the gauge board (rev A, ordered 2026-10-27).

    python.exe gauge_route_as_built.py in.kicad_pcb out.kicad_pcb

All coordinates are hard-coded for the as-built placement (J1/J2 top-left, U2 above U3, J3/J4 on the right, R5/R6
at left, filter parts between and below the modules). It is NOT general: change the placement and the numbers are
wrong. It deletes every track, via and zone first, so never run it over a board that has hand-edited routing.
Conventions it encodes (reuse them): horizontals on F.Cu, verticals on B.Cu, vias at the layer changes; power 0.5 mm,
signals 0.25 mm; ground pours on both layers with thermal reliefs; copper-pour keepout of radius 3.25 mm round each
M3 hole; GND stitching vias only where they clear everything. Read-only check: gauge_check_lengths.py.
"""
import math
import sys
import pcbnew
from pcbnew import FromMM, ToMM, VECTOR2I

src, dst = sys.argv[1], sys.argv[2]
skip_file = sys.argv[3] if len(sys.argv) > 3 else None
board = pcbnew.LoadBoard(src)

F, B = pcbnew.F_Cu, pcbnew.B_Cu
W_S, W_P = 0.25, 0.5
VIA_D, VIA_DRILL = 0.6, 0.3

for t in list(board.GetTracks()):
    board.Remove(t)
for z in list(board.Zones()):
    board.Remove(z)


def net(name):
    n = board.FindNet(name)
    assert n is not None, name
    return n


def mm(x, y):
    return VECTOR2I(FromMM(x), FromMM(y))


def track(netname, layer, pts, w):
    n = net(netname)
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(mm(x1, y1))
        t.SetEnd(mm(x2, y2))
        t.SetLayer(layer)
        t.SetWidth(FromMM(w))
        t.SetNet(n)
        board.Add(t)


def via(netname, x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetPosition(mm(x, y))
    try:
        v.SetWidth(F, FromMM(VIA_D))
        v.SetWidth(B, FromMM(VIA_D))
    except TypeError:
        v.SetWidth(FromMM(VIA_D))
    v.SetDrill(FromMM(VIA_DRILL))
    v.SetLayerPair(F, B)
    v.SetNet(net(netname))
    board.Add(v)


# ---------------------------------------------------------------- +5V
track("/+5V", B, [(30.66, 40.5), (30.66, 45.5)], W_P)                       # J1.2 - J2.2
track("/+5V", B, [(30.66, 45.5), (30.66, 50.46), (30.12, 51.0)], W_P)       # to C2.1
track("/+5V", F, [(30.12, 51.0), (30.89, 51.77), (35.62, 51.77)], W_P)      # to U1.2
track("/+5V", F, [(30.66, 40.5), (30.66, 38.0), (37.12, 38.0), (37.12, 34.0)], W_P)   # to C1.1

# ---------------------------------------------------------------- +3V3
track("/+3V3", F, [(35.62, 53.04), (37.2, 54.62), (37.2, 61.7)], W_P)       # U1.3 trunk
track("/+3V3", F, [(37.2, 60.0), (35.62, 60.0)], W_P)                       # C4.1
track("/+3V3", F, [(37.2, 61.7), (28.62, 61.7)], W_P)
track("/+3V3", F, [(28.62, 61.7), (28.62, 58.5)], W_P)                      # C3.1
track("/+3V3", F, [(28.62, 61.7), (28.62, 63.0), (27.62, 63.0)], W_P)       # TP2
track("/+3V3", F, [(33.5, 61.7), (33.5, 65.0)], W_P)                        # R5.1
track("/+3V3", F, [(37.2, 54.62), (69.3, 54.62)], W_P)                      # lane east
track("/+3V3", F, [(60.69, 54.62), (60.69, 58.5)], W_P)                     # U3.1
via("/+3V3", 69.3, 54.62)
track("/+3V3", B, [(69.3, 54.62), (69.3, 38.0)], W_P)
via("/+3V3", 69.3, 38.0)
track("/+3V3", F, [(69.3, 38.0), (60.81, 38.0), (60.81, 35.0)], W_P)        # U2.1
track("/+3V3", B, [(69.3, 50.96), (73.5, 50.96)], W_P)                      # J3.1, J3.2
track("/+3V3", B, [(69.3, 40.96), (73.5, 40.96)], W_P)                      # J4.1, J4.2

# ---------------------------------------------------------------- I2C
# SDA: bus on B.Cu at x=40, SCL: bus on B.Cu at x=41
track("/SDA", F, [(33.2, 40.5), (33.2, 39.0), (40.0, 39.0)], W_S)
track("/SDA", B, [(33.2, 40.5), (33.2, 45.5)], W_S)
track("/SDA", B, [(40.0, 32.4), (40.0, 56.62)], W_S)
for y in (32.4, 39.0, 56.62):
    via("/SDA", 40.0, y)
track("/SDA", F, [(40.0, 32.4), (53.19, 32.4), (53.19, 35.0)], W_S)         # U2.3
track("/SDA", F, [(40.0, 56.62), (53.07, 56.62)], W_S)
via("/SDA", 53.07, 56.62)
track("/SDA", B, [(53.07, 56.62), (53.07, 58.5)], W_S)                      # U3.3

track("/SCL", F, [(35.74, 40.5), (41.0, 40.5)], W_S)
track("/SCL", B, [(35.74, 40.5), (35.74, 45.5)], W_S)
track("/SCL", B, [(41.0, 31.4), (41.0, 55.62)], W_S)
for y in (31.4, 40.5, 55.62):
    via("/SCL", 41.0, y)
track("/SCL", F, [(41.0, 31.4), (55.73, 31.4), (55.73, 35.0)], W_S)         # U2.4
track("/SCL", F, [(41.0, 55.62), (55.61, 55.62)], W_S)
via("/SCL", 55.61, 55.62)
track("/SCL", B, [(55.61, 55.62), (55.61, 58.5)], W_S)                      # U3.4

# ---------------------------------------------------------------- ADS_REF (equal legs from the midpoint)
track("/ADS_REF", B, [(42.62, 53.0), (41.9, 53.72), (41.9, 75.78), (42.62, 76.5)], W_S)   # R2.1 - R4.1
track("/ADS_REF", B, [(41.9, 64.75), (39.5, 64.75), (39.5, 72.62), (33.5, 72.62)], W_S)   # R6.1, R5.2

# ---------------------------------------------------------------- channel 1
track("/ADS1_A0", F, [(58.27, 47.7), (58.27, 53.0), (55.62, 53.0)], W_S)
track("/ADS1_A0", F, [(58.27, 53.0), (58.85, 53.0)], W_S)
track("/ADS1_A1", F, [(55.73, 47.7), (55.73, 49.6), (53.12, 52.21), (53.12, 53.0), (50.24, 53.0)], W_S)
track("/ADS1_SIG", F, [(66.47, 53.0), (66.97, 53.5), (73.5, 53.5)], W_S)
# ---------------------------------------------------------------- channel 2
track("/ADS2_A0", F, [(58.15, 71.2), (58.15, 76.5), (56.12, 76.5)], W_S)
track("/ADS2_A0", F, [(58.15, 76.5), (59.12, 76.5)], W_S)
track("/ADS2_A1", F, [(55.61, 71.2), (55.61, 72.9), (53.62, 74.89), (53.62, 76.5), (50.24, 76.5)], W_S)
track("/ADS2_SIG", B, [(66.74, 76.5), (68.0, 76.5), (68.0, 43.5)], W_S)
via("/ADS2_SIG", 68.0, 43.5)
track("/ADS2_SIG", F, [(68.0, 43.5), (73.5, 43.5)], W_S)

# ---------------------------------------------------------------- GND pours + screw-head keepouts
bb = board.GetBoardEdgesBoundingBox()
x0, y0, x1, y1 = (ToMM(bb.GetLeft()), ToMM(bb.GetTop()), ToMM(bb.GetRight()), ToMM(bb.GetBottom()))
gnd = net("/GND")
for layer in (F, B):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(gnd)
    z.SetLocalClearance(FromMM(0.3))
    z.SetMinThickness(FromMM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(FromMM(0.3))
    z.SetThermalReliefSpokeWidth(FromMM(0.5))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    ol = z.Outline()
    ol.NewOutline()
    for px, py in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        ol.Append(FromMM(px), FromMM(py))
    board.Add(z)

for fp in board.GetFootprints():
    if not fp.GetReference().startswith("H"):
        continue
    c = fp.GetPosition()
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetLayerSet(pcbnew.LSET.AllCuMask())
    for name in ("SetDoNotAllowZoneFills", "SetDoNotAllowCopperPour"):
        if hasattr(z, name):
            getattr(z, name)(True)
            break
    for name in ("SetDoNotAllowTracks", "SetDoNotAllowVias", "SetDoNotAllowPads", "SetDoNotAllowFootprints"):
        if hasattr(z, name):
            getattr(z, name)(False)
    ol = z.Outline()
    ol.NewOutline()
    for k in range(32):
        a = 2 * math.pi * k / 32
        ol.Append(c.x + int(FromMM(3.25) * math.cos(a)), c.y + int(FromMM(3.25) * math.sin(a)))
    board.Add(z)

# ---------------------------------------------------------------- GND stitching vias (pruned by DRC outside)
skip = set()
if skip_file:
    for line in open(skip_file):
        line = line.strip()
        if line:
            a, b = line.split(",")
            skip.add((round(float(a), 2), round(float(b), 2)))
stitch = []
yy = y0 + 3.0
while yy < y1 - 2.0:
    xx = x0 + 3.0
    while xx < x1 - 2.0:
        stitch.append((round(xx, 2), round(yy, 2)))
        xx += 5.0
    yy += 5.0
def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    u = 0.0 if L2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return math.hypot(px - (ax + u * dx), py - (ay + u * dy))


pads = []
for fp in board.GetFootprints():
    for pd in fp.Pads():
        c = pd.GetPosition()
        r = max(ToMM(pd.GetSize().x), ToMM(pd.GetSize().y)) / 2
        pads.append((ToMM(c.x), ToMM(c.y), r))
segs, vias = [], []
for tr in board.GetTracks():
    if tr.GetClass() == "PCB_VIA":
        p = tr.GetPosition()
        vias.append((ToMM(p.x), ToMM(p.y)))
    else:
        a, b = tr.GetStart(), tr.GetEnd()
        segs.append((ToMM(a.x), ToMM(a.y), ToMM(b.x), ToMM(b.y), ToMM(tr.GetWidth()) / 2))
holes = [(ToMM(fp.GetPosition().x), ToMM(fp.GetPosition().y)) for fp in board.GetFootprints()
         if fp.GetReference().startswith("H")]
GAP = 0.45     # copper edge to copper edge, more than the 0.2 net clearance so the pour can pass


def ok(x, y):
    if x < x0 + 1.5 or x > x1 - 1.5 or y < y0 + 1.5 or y > y1 - 1.5:
        return False
    if any(math.hypot(x - hx, y - hy) < 3.25 + 0.5 for hx, hy in holes):
        return False
    if any(math.hypot(x - px, y - py) < r + 0.3 + GAP + 0.15 for px, py, r in pads):
        return False
    if any(seg_dist(x, y, *s[:4]) < s[4] + 0.3 + GAP for s in segs):
        return False
    if any(math.hypot(x - vx, y - vy) < 0.6 + GAP for vx, vy in vias):
        return False
    return True


count = 0
for p in stitch:
    if p in skip or not ok(*p):
        continue
    via("/GND", *p)
    vias.append(p)
    count += 1
print("stitch vias:", count, "of", len(stitch))

pcbnew.ZONE_FILLER(board).Fill(board.Zones())
pcbnew.SaveBoard(dst, board)
print("tracks:", len(board.GetTracks()), "zones:", len(list(board.Zones())), "->", dst)
