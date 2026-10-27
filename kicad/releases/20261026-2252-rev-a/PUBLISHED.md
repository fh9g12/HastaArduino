# Published schematic snapshot 20261026-2252-rev-a

* Published: 2026-10-26T22:52:52
* Git commit: `232b1e6`, working tree dirty (uncommitted changes in the working tree)
* ERC hastadaq: ** ERC messages: 0  Errors 0  Warnings 0
* ERC gaugeboard: ** ERC messages: 0  Errors 0  Warnings 0

Start the PCBs here: `hastadaq/hastadaq.kicad_pcb` and `gaugeboard/gaugeboard.kicad_pcb`, using
Tools > Update PCB from Schematic. This folder is a snapshot: do not re-run a generator over it. To change
the schematic after layout has begun, edit the .kicad_sch here in KiCad; to start over from regenerated
sources, run `py kicad/tools/publish.py` again and lay out in the NEW folder.
`docs/` holds the briefs as they were at publish time. The netlists (`*.net`) can be diffed between
releases to see exactly what changed.
