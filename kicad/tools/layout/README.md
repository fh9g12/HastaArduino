# kicad/tools/layout: layout, routing, silkscreen and fab scripts

Run the pcbnew ones with KiCad's own Python (`%LOCALAPPDATA%\Programs\KiCad\10.0\bin\python.exe`); `export_fab.py` and
`set_pcbway_rules.py` run with the normal `py`. Always close the PCB editor first, back the board up, and never run a
script that writes a board over hand-edited work you have not checked. See `../../README.md` for the workflow and gotchas.

| Script | Reusable? | What it does |
|---|---|---|
| `export_fab.py` | **yes, any board** | kicad-cli Gerbers (7 layers) + Excellon drill (PTH/NPTH split) + drill maps, zips the upload files. Refuses if the PCB editor has the board open. Reproduced the gauge board's PCBWay files exactly (apart from date headers). |
| `tidy_silk.py` | **yes, any board** | Re-places only reference-designator text (size and angle set, avoids pads, silk outlines, holes, board edge, each other, stays next to its part). `python.exe tidy_silk.py in out [size_mm]`. Footprint positions are never changed. |
| `remove_pads.py` | yes | Remove pads (optionally only non-plated) from named footprints on a board. Used to drop the ADS122C04 module mounting holes. |
| `set_pcbway_rules.py` | yes | Writes the PCBWay 2-layer rules (6/6 mil, 0.3 mm drill, edge clearance, default net class) into a `.kicad_pro`. |
| `gauge_initial_placement.py` | template | First-draft board creation from a netlist (footprint loading, schematic UUID path, nets, `place_pair` helper, outline, M3 holes). Its placement was superseded by the owner's hand layout. |
| `gauge_route_as_built.py` | record | The exact routing applied to the gauge board. Coordinates are hard-coded; not general. Encodes the conventions (layers, widths, pours, keepouts, stitching) worth reusing. |
| `gauge_check_lengths.py` | record | Read-only path lengths for ADS_REF legs, SIG runs, A0/A1 links on the gauge board. |
