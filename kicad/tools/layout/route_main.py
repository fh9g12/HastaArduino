"""MAIN BOARD routing: power trunks by hand, everything else with grid_router.py, then GND pours and stitching vias.

    python.exe route_main.py in.kicad_pcb out.kicad_pcb

Run with KiCad's bundled python.exe (it has pcbnew AND numpy). Removes every existing track, via and zone first, so it
is re-runnable on a PLACED board; never run it over a board whose routing you have edited by hand.

Decisions (2026-10-28):
  * VSERVO (Pololu VOUT -> C2 -> the J7 servo plugs): 2.0 mm on F.Cu, one bar down the middle (VSERVO) column of J7.
  * +12V (Pololu VIN -> C1 -> J8): 2.0 mm on B.Cu, so it never crosses the VSERVO copper; the rest of the +12V net
    (J8 pin 8, the BabyBuck VIN) is routed by the router at 0.8 mm.
  * +5V and +5V_VSYS 0.8 mm, +3V3 0.5 mm, everything else 0.25 mm. GND is NOT routed: a pour on both layers.
  * Top-layer copper is kept out of the rectangles drawn on User.Comments (the SP/CE connector area under the Pico and
    the plug-clearance zone); the bottom layer may cross them. Screw-head circles (r 3.25) keep all copper out.
"""
import math
import os
import sys
import time

import pcbnew
from pcbnew import FromMM, ToMM, VECTOR2I

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from grid_router import GridRouter, HARD  # noqa: E402

src, dst = sys.argv[1], sys.argv[2]
EXTRA_MARGIN = float(os.environ.get("ROUTE_MARGIN", "0.03"))
board = pcbnew.LoadBoard(src)
F, B = pcbnew.F_Cu, pcbnew.B_Cu
LAYER = {0: F, 1: B}

for t in list(board.GetTracks()):
    board.RemoveNative(t)
for z in list(board.Zones()):
    board.RemoveNative(z)

bb = board.GetBoardEdgesBoundingBox()
OX, OY, W, H = ToMM(bb.GetLeft()), ToMM(bb.GetTop()), ToMM(bb.GetWidth()), ToMM(bb.GetHeight())
CORNER_R = 3.0
print("board %.1f x %.1f mm, origin (%.1f, %.1f)" % (W, H, OX, OY))

HALO_R = float(os.environ.get("ROUTE_HALO", "0"))      # optional keep-out ring round GND pads (off: too greedy)
GND_PADS = {}                                             # (ref, number) -> (x, y) of every through-hole GND pad
BUS_W = 0.5
NET_WIDTH = {"+3V3": 0.5, "+5V": 0.8, "+5V_VSYS": 0.8, "+12V": 0.8}
DEFAULT_W = 0.25
widths = sorted({DEFAULT_W, 0.5, 0.8, 2.0})
router = GridRouter(W, H, widths, pitch=0.1, clearance=0.2, via_d=0.6, margin=EXTRA_MARGIN)
router.block_outside_rounded_rect(W, H, CORNER_R, 0.5)

netid = {}


def nid(name):
    if name not in netid:
        netid[name] = len(netid) + 1
    return netid[name]


def rel(p):
    return ToMM(p.x) - OX, ToMM(p.y) - OY


# ---------------------------------------------------------------- pads, holes, keep-outs
pads_by_net = {}
pad_pos = {}
anon = 20000
for fp in board.GetFootprints():
    ref = fp.GetReference()
    for pad in fp.Pads():
        name = str(pad.GetNetname()).lstrip("/")          # net names in the file start with '/'
        x, y = rel(pad.GetPosition())
        pad_pos[(ref, pad.GetNumber())] = (x, y)
        b = pad.GetBoundingBox()
        w, h = ToMM(b.GetWidth()), ToMM(b.GetHeight())
        bx, by = ToMM(b.GetCenter().x) - OX, ToMM(b.GetCenter().y) - OY
        if pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH:      # mounting / module holes: a hard keep-out
            router.mark(("circle", x, y, max(ToMM(pad.GetDrillSize().x), ToMM(pad.GetDrillSize().y)) / 2 + 0.1), HARD, [0, 1])
            continue
        layers = [l for l, lay in LAYER.items() if pad.IsOnLayer(lay)]
        drill = max(ToMM(pad.GetDrillSize().x), ToMM(pad.GetDrillSize().y))
        if drill > 0:                                         # a via hole must keep hole-to-hole spacing from this one
            router.block_via(x, y, drill / 2 + 0.15 + 0.3 + 0.1)
        if name:
            net = nid(name)
        else:
            anon += 1
            net = anon
        shape = pad.GetShape()
        if shape == pcbnew.PAD_SHAPE_CIRCLE:
            geo = ("circle", bx, by, w / 2)
        elif shape == pcbnew.PAD_SHAPE_OVAL:
            r = min(w, h) / 2
            if w >= h:
                geo = ("seg", bx - (w / 2 - r), by, bx + (w / 2 - r), by, r)
            else:
                geo = ("seg", bx, by - (h / 2 - r), bx, by + (h / 2 - r), r)
        else:
            geo = ("rect", bx - w / 2, by - h / 2, bx + w / 2, by + h / 2)
        router.mark(geo, net, layers)
        if name == "GND" and drill > 0:
            GND_PADS[(ref, pad.GetNumber())] = (x, y)
            if HALO_R:
                router.mark(("circle", x, y, HALO_R), HARD, layers)
        if name and not name.startswith("unconnected"):
            pads_by_net.setdefault(name, []).append(dict(x=x, y=y, layers=layers, ref=ref, num=pad.GetNumber()))

for fp in board.GetFootprints():                                # screw-head circles (guideline: keep copper out)
    if fp.GetReference().startswith("H"):
        x, y = rel(fp.GetPosition())
        router.mark(("circle", x, y, 3.25), HARD, [0, 1])

user_rects = []
for d in board.GetDrawings():
    if d.GetLayer() == pcbnew.Cmts_User and d.GetClass() == "PCB_SHAPE" and d.GetShape() == pcbnew.SHAPE_T_RECT:
        r = d.GetBoundingBox()
        user_rects.append((ToMM(r.GetLeft()) - OX, ToMM(r.GetTop()) - OY, ToMM(r.GetRight()) - OX, ToMM(r.GetBottom()) - OY))
# The rectangles mark where no COMPONENT may go (SP/CE connector under the Pico, plug clearance behind it). Copper is
# fine there unless ROUTE_KEEP_TOP=1 asks for the old, stricter top-layer keep-out.
KEEP_TOP = os.environ.get("ROUTE_KEEP_TOP", "0") == "1"
for (x0, y0, x1, y1) in user_rects:
    if KEEP_TOP:
        router.mark(("rect", x0, y0, x1, y1), HARD, [0])
print("top-layer keep-out rectangles:", [tuple(round(v, 1) for v in r) for r in user_rects])

# Rule areas that live inside footprints (the stock Pico footprint has a Pico-W "Antenna Copper Keep Out" on both
# copper layers, 14 mm wide between the header rows): no track or via, on any layer it covers.
fp_keepouts = []
for fp in board.GetFootprints():
    for z in fp.Zones():
        if z.GetIsRuleArea() and z.GetDoNotAllowTracks():
            r = z.GetBoundingBox()
            box = (ToMM(r.GetLeft()) - OX, ToMM(r.GetTop()) - OY, ToMM(r.GetRight()) - OX, ToMM(r.GetBottom()) - OY)
            lays = [l for l, lay in LAYER.items() if z.IsOnLayer(lay)]
            router.mark(("rect",) + box, HARD, lays)
            for l in lays:
                fp_keepouts.append((box, l))
            print("footprint keep-out %s %s on %s" % (fp.GetReference(), z.GetZoneName(), lays))


def add_track(name, layer, pts, width, existing=None):
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(VECTOR2I(FromMM(x0 + OX), FromMM(y0 + OY)))
        t.SetEnd(VECTOR2I(FromMM(x1 + OX), FromMM(y1 + OY)))
        t.SetLayer(LAYER[layer])
        t.SetWidth(FromMM(width))
        t.SetNet(board.FindNet("/" + name))
        board.Add(t)
    router.mark_track(nid(name), layer, pts, width)
    if existing is not None:
        existing.setdefault(name, []).append((layer, pts))


def add_via(name, x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetPosition(VECTOR2I(FromMM(x + OX), FromMM(y + OY)))
    try:
        v.SetWidth(F, FromMM(0.6))
        v.SetWidth(B, FromMM(0.6))
    except TypeError:
        v.SetWidth(FromMM(0.6))
    v.SetDrill(FromMM(0.3))
    v.SetLayerPair(F, B)
    v.SetNet(board.FindNet("/" + name))
    board.Add(v)


# ---------------------------------------------------------------- hand-routed power trunks
existing = {}
P = lambda ref, n: pad_pos[(ref, str(n))]

# VSERVO on F.Cu, 2.0 mm: VOUT pads -> down -> across to C2 -> down to y 57 -> onto the VSERVO column of J7
vs_col = [P("J7", n) for n in (17, 14, 11, 8, 5, 2)]            # top to bottom
vo1, vo2, c2 = P("U2", 1), P("U2", 2), P("C2", 1)
vs = [vo1, vo2, (vo2[0], 51.0), (c2[0], 51.0), c2, (c2[0], 57.0), (vs_col[0][0], 57.0)] + vs_col
add_track("VSERVO", 0, vs, 2.0, existing)

# +12V on B.Cu, 2.0 mm: Pololu VIN pads -> down -> across -> C1 -> J8 pin 1
vi1, vi2, c1, j8 = P("U2", 7), P("U2", 8), P("C1", 1), P("J8", 1)
v12 = [vi1, vi2, (vi2[0], 50.0), (c1[0], 50.0), c1, j8]
add_track("+12V", 1, v12, 2.0, existing)

# ---------------------------------------------------------------- GND buses
# Groups of through-hole GND pads that are routed together by real tracks first (ROUTE_GNDBUS="U1.18+U1.23,U1.13+R11.2",
# groups separated by commas, pads by plus signs): e.g. the Pico's mid-row GND pins and the GND pads of the parts hidden
# under it, which the pours alone reach only by chance.
for grp in [g for g in os.environ.get("ROUTE_GNDBUS", "").split(",") if g]:
    keys = [tuple(k.split(".")) for k in grp.split("+")]
    pads = [dict(x=GND_PADS[k][0], y=GND_PADS[k][1], layers=[0, 1], ref=k[0], num=k[1]) for k in keys if k in GND_PADS]
    res = router.route_net(nid("GND"), BUS_W, pads)
    for layer, pts, width in res["tracks"]:
        add_track("GND", layer, pts, width)
    for x, y in res["vias"]:
        add_via("GND", x, y)
    print("GND bus %s: %d tracks, %d vias%s" % (grp, len(res["tracks"]), len(res["vias"]), " FAILED " + str([(p["ref"], p["num"]) for p in res["failed"]]) if res["failed"] else ""))

# ---------------------------------------------------------------- GND stubs and ties
# A through-hole GND pad squeezed between other tracks (or ringed by a power bar) can end up on a pour island. The first
# attempt finds the stranded pads; the next gives each a short stub and a via (ties the top and bottom pours together
# right beside the pad, ROUTE_GNDSTUB); a pad still stranded after that gets a real track to the nearest GND pad that is
# connected (ROUTE_GNDTIE). Both are placed BEFORE the signals, so they do not have to squeeze in afterwards.
gnd_id = nid("GND")
c25 = router.classes.index(DEFAULT_W)
vcls = len(router.classes) - 1
env_list = lambda name: [k for k in os.environ.get(name, "").split(",") if k]
for key in env_list("ROUTE_GNDSTUB"):
    ref, num = key.split(".")
    if (ref, num) not in GND_PADS or key in env_list("ROUTE_GNDTIE"):
        continue
    px, py = GND_PADS[(ref, num)]
    done = False
    for length in (1.4, 1.8, 2.3, 2.9):
        for ang in range(0, 360, 15):
            vx, vy = px + length * math.cos(math.radians(ang)), py + length * math.sin(math.radians(ang))
            vix, viy = router._cell(vx, vy)
            if not (0 <= vix < router.nx and 0 <= viy < router.ny):
                continue
            if router.no_via[viy][vix] or router.owner[vcls][0][viy][vix] not in (0, gnd_id) or router.owner[vcls][1][viy][vix] not in (0, gnd_id):
                continue
            for layer in (1, 0):
                n = int(length / router.p)
                ok = True
                for k in range(3, n + 1):                      # skip the first 0.3 mm: it is inside the pad itself
                    cx_, cy_ = router._cell(px + (vx - px) * k / n, py + (vy - py) * k / n)
                    if router.owner[c25][layer][cy_][cx_] not in (0, gnd_id):
                        ok = False
                        break
                if ok:
                    pts = [(px, py), (round(vix * router.p, 3), round(viy * router.p, 3))]
                    add_track("GND", layer, pts, DEFAULT_W)
                    add_via("GND", pts[1][0], pts[1][1])
                    router.mark_via(gnd_id, pts[1][0], pts[1][1])
                    done = True
                    break
            if done:
                break
        if done:
            break
    print("GND stub for %s.%s: %s" % (ref, num, "placed" if done else "NO ROOM"))

pending = env_list("ROUTE_GNDTIE")
for key in env_list("ROUTE_GNDTIE"):
    pending.remove(key)                                        # pads tied earlier in this loop count as anchors
    ref, num = key.split(".")
    if (ref, num) not in GND_PADS:
        continue
    px, py = GND_PADS[(ref, num)]
    anchors = sorted(((math.hypot(ax - px, ay - py), k) for k, (ax, ay) in GND_PADS.items()
                      if "%s.%s" % k not in pending and "%s.%s" % k not in env_list("ROUTE_GNDSTUB") + [key]),
                     key=lambda t: t[0])
    ok = False
    for dist, ak in anchors[:6]:
        ax, ay = GND_PADS[ak]
        res = router.route_net(gnd_id, DEFAULT_W, [dict(x=px, y=py, layers=[0, 1]), dict(x=ax, y=ay, layers=[0, 1])])
        if not res["failed"]:
            for layer, pts, width in res["tracks"]:
                add_track("GND", layer, pts, width)
            for x, y in res["vias"]:
                add_via("GND", x, y)
            ok = True
            print("GND tie %s.%s -> %s.%s (%.1f mm)" % (ref, num, ak[0], ak[1], dist))
            break
    if not ok:
        print("GND tie %s.%s: NO PATH" % (ref, num))

# ---------------------------------------------------------------- autoroute the rest
order = []
for name, pads in pads_by_net.items():
    if name == "GND" or len(pads) < 2:
        continue
    xs = [p["x"] for p in pads]
    ys = [p["y"] for p in pads]
    w = NET_WIDTH.get(name, DEFAULT_W)
    # nets with a pad in or beside a keep-out are the hardest to escape: route them first, before the space fills up
    boxes = user_rects + [b for b, _ in fp_keepouts]
    tight = any(b[0] - 3 <= p["x"] <= b[2] + 3 and b[1] - 3 <= p["y"] <= b[3] + 3 for p in pads for b in boxes)
    first = os.environ.get("ROUTE_FIRST", "").split(",")      # nets that failed on an earlier attempt (see below)
    order.append((-1 if name in first else 0 if tight else 1, -w, math.hypot(max(xs) - min(xs), max(ys) - min(ys)), name))
order.sort()

t0 = time.time()
failed = {}
for _, _, _, name in order:
    pads = pads_by_net[name]
    w = NET_WIDTH.get(name, DEFAULT_W)
    res = router.route_net(nid(name), w, pads, existing=existing.get(name, []))
    for layer, pts, width in res["tracks"]:
        # snap the ends of a track onto the exact pad centre if it finished on one
        pts = list(pts)
        for end in (0, -1):
            for pd in pads:
                if math.hypot(pts[end][0] - pd["x"], pts[end][1] - pd["y"]) < 0.12:
                    pts[end] = (pd["x"], pd["y"])
        add_track(name, layer, pts, width)
    for x, y in res["vias"]:
        add_via(name, x, y)
    if res["failed"]:
        failed[name] = [(p["ref"], p["num"]) for p in res["failed"]]
        if os.environ.get("ROUTE_DEBUG"):
            for p in res["failed"]:
                print(router.ascii_map(p["x"], p["y"], 5.0, w, nid(name)))
    print("%-14s w %.2f pads %2d tracks %2d vias %d %s  (%.0fs)" % (
        name, w, len(pads), len(res["tracks"]), len(res["vias"]),
        "FAILED " + str(failed[name]) if name in failed else "ok", time.time() - t0))
print("routing done in %.0fs; nets with failures: %s" % (time.time() - t0, failed or "none"))

# ---------------------------------------------------------------- GND pours, keep-outs, stitching
gnd = board.FindNet("/GND")
for layer in (F, B):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(gnd)
    z.SetLocalClearance(FromMM(0.3))
    z.SetMinThickness(FromMM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(FromMM(0.25))
    z.SetThermalReliefSpokeWidth(FromMM(0.4))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    ol = z.Outline()
    ol.NewOutline()
    for px, py in ((OX, OY), (OX + W, OY), (OX + W, OY + H), (OX, OY + H)):
        ol.Append(FromMM(px), FromMM(py))
    board.Add(z)


def keepout(points, layers):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    ls = pcbnew.LSET()
    for l in layers:
        ls.AddLayer(l)
    z.SetLayerSet(ls)
    for name in ("SetDoNotAllowZoneFills", "SetDoNotAllowCopperPour"):
        if hasattr(z, name):
            getattr(z, name)(True)
            break
    for name in ("SetDoNotAllowTracks", "SetDoNotAllowVias", "SetDoNotAllowPads", "SetDoNotAllowFootprints"):
        if hasattr(z, name):
            getattr(z, name)(False)
    ol = z.Outline()
    ol.NewOutline()
    for px, py in points:
        ol.Append(FromMM(px + OX), FromMM(py + OY))
    board.Add(z)


for fp in board.GetFootprints():
    if fp.GetReference().startswith("H"):
        x, y = rel(fp.GetPosition())
        keepout([(x + 3.25 * math.cos(2 * math.pi * k / 32), y + 3.25 * math.sin(2 * math.pi * k / 32)) for k in range(32)], [F, B])
for (x0, y0, x1, y1) in user_rects:
    if KEEP_TOP:
        keepout([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], [F])

vcls = len(router.classes) - 1
count = 0
vias_gnd = []
yy = 3.0
while yy < H - 2:
    xx = 3.0
    while xx < W - 2:
        ix, iy = router._cell(xx, yy)
        if router.owner[vcls][0][iy][ix] == 0 and router.owner[vcls][1][iy][ix] == 0:
            add_via("GND", xx, yy)
            router.mark_via(nid("GND"), xx, yy)
            count += 1
        xx += 6.0
    yy += 6.0
print("GND stitching vias:", count)

pcbnew.ZONE_FILLER(board).Fill(board.Zones())
# ---------------------------------------------------------------- stranded GND pads / failed nets -> try again
board.BuildConnectivity()
conn = board.GetConnectivity()
sizes = {(fp.GetReference(), p.GetNumber()): len(conn.GetConnectedItems(p))
         for fp in board.GetFootprints() for p in fp.Pads() if str(p.GetNetname()) == "/GND"}
main = max(sizes.values())
stray = sorted("%s.%s" % k for k, v in sizes.items() if v < main * 0.5 and k in GND_PADS)
print("stranded GND pads:", stray or "none")
attempt = int(os.environ.get("ROUTE_ATTEMPT", "1"))
new_first = [n for n in failed if n not in os.environ.get("ROUTE_FIRST", "").split(",")]
stubbed = env_list("ROUTE_GNDSTUB")
new_stub = [k for k in stray if k not in stubbed]
new_tie = [k for k in stray if k in stubbed and k not in env_list("ROUTE_GNDTIE")]    # a stub did not rescue these
if (new_first or new_stub or new_tie) and attempt < 8:     # no rip-up in the router: start again, failed nets first, stubs for strays
    os.environ["ROUTE_FIRST"] = ",".join([n for n in os.environ.get("ROUTE_FIRST", "").split(",") if n] + new_first)
    os.environ["ROUTE_GNDSTUB"] = ",".join([n for n in os.environ.get("ROUTE_GNDSTUB", "").split(",") if n] + new_stub)
    os.environ["ROUTE_GNDTIE"] = ",".join(env_list("ROUTE_GNDTIE") + new_tie)
    os.environ["ROUTE_ATTEMPT"] = str(attempt + 1)
    print("attempt %d: retry, nets first: %s, GND stubs: %s, ties: %s" % (attempt, os.environ["ROUTE_FIRST"], os.environ["ROUTE_GNDSTUB"], os.environ["ROUTE_GNDTIE"]))
    sys.stdout.flush()
    os.execv(sys.executable, [sys.executable] + sys.argv)
pcbnew.SaveBoard(dst, board)
print("tracks+vias:", len(board.GetTracks()), "-> wrote", dst)
