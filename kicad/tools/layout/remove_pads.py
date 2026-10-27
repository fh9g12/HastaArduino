"""Remove pads from named footprints on a board (placement and everything else is left alone).

    python.exe remove_pads.py in.kicad_pcb out.kicad_pcb REF[,REF...] [--npth-only]

Used on the gauge board to delete the ADS122C04 breakouts' four 2.5 mm mounting holes (U2, U3), which the
owner did not want: `remove_pads.py gaugeboard.kicad_pcb gaugeboard.kicad_pcb U2,U3 --npth-only`.
The library footprint is NOT changed, so a later "Update footprints from library" would bring the pads back.
Run it with KiCad's bundled python.exe (it has pcbnew) and with the PCB editor closed.
"""
import sys
import pcbnew

src, dst = sys.argv[1], sys.argv[2]
refs = set(sys.argv[3].split(","))
npth_only = "--npth-only" in sys.argv

board = pcbnew.LoadBoard(src)
removed = 0
for fp in board.GetFootprints():
    if fp.GetReference() not in refs:
        continue
    pads = fp.Pads()                       # do not wrap in list(): the SWIG container is not list()-able
    doomed = [p for p in pads if not npth_only or p.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH]
    for p in doomed:
        fp.Remove(p)
        removed += 1
pcbnew.SaveBoard(dst, board)
print("removed pads:", removed)
