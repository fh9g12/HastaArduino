"""Give the pads that a DRC report calls "starved thermal" a solid connection to the pour (no thermal-relief spokes).

    python.exe solid_gnd_pads.py board.kicad_pcb drc.rpt [out.kicad_pcb]

A through-hole pad squeezed between tracks can get only one relief spoke on a layer, which KiCad flags (it wants two).
Such a pad IS connected, but one thin spoke is a weak joint, so the zone is told to join that pad solid instead. Costs a
little soldering heat on those few pins. Re-fills the zones and saves (over the input board if no out path is given).
"""
import re
import sys

import pcbnew

src, rpt = sys.argv[1], sys.argv[2]
dst = sys.argv[3] if len(sys.argv) > 3 else src
board = pcbnew.LoadBoard(src)
text = open(rpt, encoding="utf-8").read()
pads = set(re.findall(r"\[starved_thermal\].*?\n(?:.*\n){0,3}?\s*@\([^)]*\): PTH pad (\S+) \[[^\]]*\] of (\S+)", text))
count = 0
for num, ref in sorted(pads):
    fp = board.FindFootprintByReference(ref)
    for pad in fp.Pads():
        if pad.GetNumber() == num:
            pad.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)
            count += 1
            print("solid:", ref, num)
pcbnew.ZONE_FILLER(board).Fill(board.Zones())
pcbnew.SaveBoard(dst, board)
print("%d pad(s) set to solid; wrote %s" % (count, dst))
