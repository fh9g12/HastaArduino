# Start here: PCB layout for release 20261026-2252-rev-a

This folder is a self-contained snapshot of two boards. Lay both out **in this folder**, not in the repository's
working `kicad/hastadaq` or `kicad/gaugeboard`.

1. Read `docs/PCB_BRIEF.md` (main board, and the shared rules) section 0 first, then `docs/PCB_BRIEF_GAUGE.md`.
   `docs/PARTS_TO_SELECT.md` lists every part with its RS number and footprint. `PUBLISHED.md` has the git
   commit and ERC result this snapshot was made from.
2. **Path translation.** The briefs were written against the repository. Where they say `kicad/hastadaq/`
   read `hastadaq/` here, and `kicad/gaugeboard/` is `gaugeboard/`. `kicad/tools/` (the generators and
   `publish.py`) and `docs/README.md` are **not** in this folder and are not needed. The loom wiring diagram
   `wiring/gauge-loom.yml` is here. The gauge board's footprint library path
   (`../hastadaq/HastaDAQ.pretty`) works as laid out here, so keep the two board folders side by side.
3. **Make the boards:** open `hastadaq/hastadaq.kicad_pro` and `gaugeboard/gaugeboard.kicad_pro` in KiCad 10,
   create `hastadaq.kicad_pcb` / `gaugeboard.kicad_pcb` next to each schematic, then Tools > Update PCB from
   Schematic. The schematics are already ERC-clean.
4. **Rules already decided:** PCBWay standard 2-layer, 1.6 mm, 6/6 mil minimum track and space, 0.3 mm minimum
   drill, no edge connectors; M3 mounting holes in each corner; everything on the top face; all connectors the
   same way; placement guidelines are in section 7 of each brief. (Briefs, section 0, list the other owner
   decisions: do not reopen them.)
5. **Still needed from the owner before routing:** the exact board outlines and enclosure limits (ask), and how
   the two boards sit side by side.
6. **Do not re-run a generator over this folder.** To fix the schematic here, edit the `.kicad_sch` in KiCad
   and tell the owner so the docs can be updated. Large schematic changes: publish a new release from the
   repository (`py kicad/tools/publish.py`) and start layout again in the new folder.
7. The `docs/` here are a snapshot taken when this release was published; the repository's `docs/` may move on.
