"""Shorten a footprint's own keep-out rule area (e.g. the Pico footprint's "Antenna Copper Keep Out") on one board.

    python.exe trim_fp_keepout.py in.kicad_pcb out.kicad_pcb REF TRIM_MM

Moves the rule area's top edge (every vertex at the smallest Y) down by TRIM_MM, i.e. cuts that much off the side facing
the module body, for a footprint at 0 degrees. Only that board's copy changes; the library footprint does not (DRC then
shows lib_footprint_mismatch for REF, and "Update footprints from library" would restore the full area). Run with KiCad's
python.exe, PCB editor closed.
"""
import sys

import pcbnew
from pcbnew import FromMM, ToMM, VECTOR2I

src, dst, ref, trim = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
board = pcbnew.LoadBoard(src)
fp = board.FindFootprintByReference(ref)
done = 0
for z in fp.Zones():
    if not (z.GetIsRuleArea() and z.GetDoNotAllowTracks()):
        continue
    ol = z.Outline().COutline(0)
    pts = [ol.CPoint(i) for i in range(ol.PointCount())]
    top = min(p.y for p in pts)
    for i, p in enumerate(pts):
        if p.y == top:
            ol.SetPoint(i, VECTOR2I(p.x, p.y + FromMM(trim)))
    bb = z.GetBoundingBox()
    print("%s: %s now spans y %.2f..%.2f" % (ref, z.GetZoneName(), ToMM(bb.GetTop()), ToMM(bb.GetBottom())))
    done += 1
pcbnew.SaveBoard(dst, board)
print("trimmed %d rule area(s) by %.1f mm; wrote %s" % (done, trim, dst))
