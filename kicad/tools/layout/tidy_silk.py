"""Re-place ONLY the reference-designator texts of a board so they do not touch pads, silk outlines, holes,
the board edge or each other. Footprint positions are never changed.

  python.exe tidy_silk.py in.kicad_pcb out.kicad_pcb [text_size_mm]
"""
import sys
import pcbnew
from pcbnew import FromMM, ToMM, VECTOR2I, BOX2I

src, dst = sys.argv[1], sys.argv[2]
SIZE = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
board = pcbnew.LoadBoard(src)

SILK_CLR = FromMM(0.12)
PAD_CLR = FromMM(0.2)
EDGE_CLR = FromMM(0.7)


def inflated(box, amount):
    b = BOX2I(box.GetPosition(), box.GetSize())
    b.Inflate(amount)
    return b


def thin_edges(box, t):
    """The four edges of a rectangle's bounding box as thin boxes (so its interior stays free)."""
    x, y, w, h = box.GetX(), box.GetY(), box.GetWidth(), box.GetHeight()
    return [BOX2I(VECTOR2I(x, y), VECTOR2I(w, 0)), BOX2I(VECTOR2I(x, y + h), VECTOR2I(w, 0)),
            BOX2I(VECTOR2I(x, y), VECTOR2I(0, h)), BOX2I(VECTOR2I(x + w, y), VECTOR2I(0, h))]


obstacles = []   # inflated boxes that text must not overlap
for fp in board.GetFootprints():
    for pad in fp.Pads():
        big = pad.GetDrillSize().x > FromMM(2.0) or pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH
        obstacles.append(inflated(pad.GetBoundingBox(), FromMM(0.8) if big else PAD_CLR))
    for item in fp.GraphicalItems():
        if item.GetLayer() != pcbnew.F_SilkS:
            continue
        if hasattr(item, "GetShape") and item.GetShape() == pcbnew.SHAPE_T_RECT:
            obstacles += [inflated(e, SILK_CLR + FromMM(0.1)) for e in thin_edges(item.GetBoundingBox(), 0)]
        else:
            obstacles.append(inflated(item.GetBoundingBox(), SILK_CLR))
board_edges = []
outline = None
for d in board.GetDrawings():
    if d.GetLayer() == pcbnew.Edge_Cuts:
        board_edges.append(inflated(d.GetBoundingBox(), EDGE_CLR))
        outline = d.GetBoundingBox() if outline is None else (outline.Merge(d.GetBoundingBox()) or outline)
    elif d.GetLayer() == pcbnew.F_SilkS:
        obstacles.append(inflated(d.GetBoundingBox(), SILK_CLR))
outline = board.GetBoardEdgesBoundingBox()

refs = sorted([fp for fp in board.GetFootprints() if fp.Reference().IsVisible()],
              key=lambda f: (-(f.GetBoundingBox(False).GetWidth() * f.GetBoundingBox(False).GetHeight()),
                             f.GetReference()))

# park every reference far away first so old positions do not count as obstacles
for fp in refs:
    t = fp.Reference()
    t.SetTextAngleDegrees(0)
    t.SetTextSize(VECTOR2I(FromMM(SIZE), FromMM(SIZE)))
    t.SetTextThickness(FromMM(0.15))
    t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER)
    t.SetVertJustify(pcbnew.GR_TEXT_V_ALIGN_CENTER)
    t.SetPosition(VECTOR2I(FromMM(-500), FromMM(-500)))

placed = []


def centred_box(t, cx, cy):
    t.SetPosition(VECTOR2I(int(cx), int(cy)))
    b = t.GetBoundingBox()
    t.SetPosition(VECTOR2I(int(cx - (b.GetCenter().x - cx)), int(cy - (b.GetCenter().y - cy))))
    return t.GetBoundingBox()


def free(box, extra=()):
    # inside the board, away from the edge
    inner = inflated(outline, -EDGE_CLR)
    if not (inner.Contains(box.GetPosition()) and
            inner.Contains(VECTOR2I(box.GetRight(), box.GetBottom()))):
        return False
    probe = inflated(box, FromMM(0.05))
    for o in obstacles:
        if probe.Intersects(o):
            return False
    for p in placed:
        if probe.Intersects(inflated(p, SILK_CLR)):
            return False
    for e in extra:
        if probe.Intersects(e):
            return False
    return True


silk_box = {}
for fp in board.GetFootprints():
    box = None
    for item in fp.GraphicalItems():
        if item.GetLayer() == pcbnew.F_SilkS:
            b = item.GetBoundingBox()
            if box is None:
                box = BOX2I(b.GetPosition(), b.GetSize())
            else:
                box.Merge(b)
    if box is not None:
        silk_box[fp.GetReference()] = box

failed = []
MAX_GAP = 3.6   # mm from the part's body: a label must stay next to its part


def try_place(fp, size, max_gap):
    t = fp.Reference()
    t.SetTextSize(VECTOR2I(FromMM(size), FromMM(size)))
    B = BOX2I(silk_box[fp.GetReference()].GetPosition(), silk_box[fp.GetReference()].GetSize())
    for pad in fp.Pads():
        if pad.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH:
            B.Merge(pad.GetBoundingBox())
    cx, cy = B.GetCenter().x, B.GetCenter().y
    probe = centred_box(t, cx, cy)
    w, h = probe.GetWidth(), probe.GetHeight()
    extra = [inflated(silk_box[o.GetReference()], FromMM(0.1)) for o in board.GetFootprints()
             if o is not fp and o.GetReference() in silk_box]
    cands = []
    if B.GetWidth() > FromMM(15) and B.GetHeight() > FromMM(15):   # a big module: its empty middle is best
        for dy in range(-6, 7):
            for dx in range(-6, 7):
                cands.append((abs(dx) + abs(dy), cx + FromMM(dx), cy + FromMM(dy)))
    step = FromMM(0.5)
    for gi in range(0, int(max_gap / 0.4)):
        g = FromMM(0.4) + gi * FromMM(0.4)
        for k in range(0, 60):
            for sgn in ((1, -1) if k else (1,)):
                s = sgn * k * step
                sc = 100 + ToMM(g) * 2 + k * 0.1
                cands.append((sc, cx + s, B.GetTop() - g - h / 2))            # above
                cands.append((sc + 0.05, cx + s, B.GetBottom() + g + h / 2))  # below
                sc2 = sc + 0.6
                cands.append((sc2, B.GetLeft() - g - w / 2, cy + s))          # left
                cands.append((sc2, B.GetRight() + g + w / 2, cy + s))         # right
    cands.sort(key=lambda c: c[0])
    for _, x, y in cands:
        box = centred_box(t, x, y)
        if free(box, extra):
            return box
    return None


for fp in refs:
    ok = try_place(fp, SIZE, 5.0)
    if ok is None:
        failed.append(fp.GetReference())
    else:
        placed.append(ok)

pcbnew.SaveBoard(dst, board)
print("wrote", dst, "| could not place:", failed or "none")
for fp in sorted(board.GetFootprints(), key=lambda f: f.GetReference()):
    p = fp.Reference().GetPosition()
    if fp.Reference().IsVisible():
        print("%-4s ref at %6.2f %6.2f" % (fp.GetReference(), ToMM(p.x), ToMM(p.y)))
