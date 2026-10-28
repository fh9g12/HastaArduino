# Published schematic snapshot 20261027-2346-rev-a-ssi

* Published: 2026-10-27T23:46:09
* Git commit: `b193da0`, working tree dirty (uncommitted changes in the working tree)
* ERC hastadaq: ** ERC messages: 0  Errors 0  Warnings 0
* ERC gaugeboard: ** ERC messages: 0  Errors 0  Warnings 0

Start the PCBs here: `hastadaq/hastadaq.kicad_pcb` and `gaugeboard/gaugeboard.kicad_pcb`, using
Tools > Update PCB from Schematic. This folder is a snapshot: do not re-run a generator over it. To change
the schematic after layout has begun, edit the .kicad_sch here in KiCad; to start over from regenerated
sources, run `py kicad/tools/publish.py` again and lay out in the NEW folder.
`docs/` holds the briefs as they were at publish time. The netlists (`*.net`) can be diffed between
releases to see exactly what changed.

## Merged into the final revision (2026-10-28)

This folder is the single final rev A. It was assembled from two earlier snapshots: `hastadaq/`, `docs/`, `wiring/` from
`20261027-2346-rev-a-ssi`, and the laid-out, ordered `gaugeboard/` (with its fab files) from `20261026-2252-rev-a`. Both boards
were ordered from PCBWay (gauge 2026-10-27, main 2026-10-28). Both snapshot folders were removed; git history has them.
The text above describes the later snapshot.
