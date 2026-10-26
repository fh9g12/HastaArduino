# Published schematic snapshot 20261026-1658-rev-a

* Published: 2026-10-26T16:58:33
* Git commit: `eeeed2c`, working tree clean
* ERC hastadaq: ** ERC messages: 0  Errors 0  Warnings 0
* ERC gaugeboard: ** ERC messages: 0  Errors 0  Warnings 0

Start the PCBs here: `hastadaq/hastadaq.kicad_pcb` and `gaugeboard/gaugeboard.kicad_pcb`, using
Tools > Update PCB from Schematic. This folder is a snapshot: do not re-run a generator over it. To change
the schematic after layout has begun, edit the .kicad_sch here in KiCad; to start over from regenerated
sources, run `py kicad/tools/publish.py` again and lay out in the NEW folder.
`docs/` holds the briefs as they were at publish time. The netlists (`*.net`) can be diffed between
releases to see exactly what changed.
