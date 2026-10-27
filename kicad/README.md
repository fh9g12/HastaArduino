# kicad/: schematics, PCB layout and fabrication

Everything electrical for the HastaDAQ REV A hardware. Two boards: the **main board** (`hastadaq/`) and the
**strain-gauge board** (`gaugeboard/`), joined by a 4-wire I2C loom (GND, +5V, SDA, SCL). Design decisions and
the per-board briefs are in `../docs/` (`PCB_BRIEF.md`, `PCB_BRIEF_GAUGE.md`, `PARTS_TO_SELECT.md`); the repo-wide
overview is `../docs/README.md`. This file covers the *workflow*, the *tools* and what a new agent or person
needs to know before laying out the next board.

## Status (2026-10-27)

| Board | Schematic | PCB layout | Fabrication |
|---|---|---|---|
| Gauge board (`gaugeboard/`) | done, ERC clean | **done**, DRC clean (only cosmetic library-mismatch warnings) | **ordered from PCBWay 2026-10-27** (board type, single or panel, chosen by the owner) |
| Main board (`hastadaq/`) | done, ERC clean | **not started** | not started |

The laid-out gauge board lives in `releases/20261026-2252-rev-a/gaugeboard/gaugeboard.kicad_pcb`, with the exact
files sent to the fab in `releases/20261026-2252-rev-a/gaugeboard/fab/` (`gaugeboard_gerbers.zip` and the
`gerbers/` folder). **Commit that release folder**: it is the as-built record.

Not verified on hardware yet: the second ADS122C04's address (expected 0x41), I2C over the loom, servo noise
on the gauge board's 3V3. The Gerbers were checked by DRC and by counting holes against the board, not in a
third-party Gerber viewer (the owner looked at PCBWay's preview).

## Folder map

```
hastadaq/                 main board: schematic, symbol library, HastaDAQ.pretty (footprints shared by BOTH boards)
gaugeboard/               gauge board: schematic (working copy; the PCB is in a release folder, see below)
releases/<stamp>-rev-a/   frozen snapshot made by publish.py: schematics, netlists, docs and (once started) the .kicad_pcb
                          files and fab/ output. LAY OUT AND ORDER FROM A RELEASE FOLDER, never from hastadaq/ or gaugeboard/.
tools/                    generators and helpers (see below)
tools/layout/             layout, routing, silkscreen and fab scripts (see tools/layout/README.md)
```

## Workflow

1. **Schematic** (bootstrap only): `py kicad/tools/generate_gauge_sch.py` / `generate_hastadaq_sch.py`. These reassign
   reference designators and UUIDs on every run, so they are only for the time **before** a `.kicad_pcb` exists.
2. **Publish**: `py kicad/tools/publish.py --label rev-a` copies both schematics, libraries, netlists, PDFs and the docs
   into a new `releases/<date-time>-rev-a/` folder (it refuses to run if ERC is not clean). Releases are never overwritten.
3. **Lay out inside the release folder**: open `<board>.kicad_pro`, create `<board>.kicad_pcb`, Tools > Update PCB from
   Schematic. From here on **edit the schematic in KiCad and never re-run a generator over that release**. If the schematic
   needs a big change, delete or abandon the release, fix the generator, and publish a NEW one (this happened once: J3/J4
   became 2x3 headers, the first release was deleted and `20261026-2252-rev-a` replaced it).
4. **Fab files**: `py kicad/tools/layout/export_fab.py releases/<rel>/<board>/<board>.kicad_pcb`
   (Gerbers + drill + zip, the PCBWay upload). Close the PCB editor first.
5. Check before ordering: `kicad-cli pcb drc --refill-zones --schematic-parity ...` shows no errors and "0 unconnected pads".

## Tools on this machine

* KiCad 10.0.6 is installed per user at `%LOCALAPPDATA%\Programs\KiCad\10.0\bin\` (not on PATH): `kicad-cli.exe` (ERC, DRC,
  netlist, Gerbers, SVG/3D render) and `python.exe` with the `pcbnew` API. Use that `python.exe` for any script that
  touches a board (the system `py` has no pcbnew).
* **No autorouter ships with KiCad.** The gauge board was routed by script (`tools/layout/gauge_route_as_built.py`).
  See "Faster routing for future boards" below.
* Previews: `kicad-cli pcb render` crops oddly; for a whole-board picture use `kicad-cli pcb export svg` (layers
  `F.Cu,B.Cu,F.SilkS,Edge.Cuts`, `--mode-single --page-size-mode 2`) and rasterise with `pymupdf`.
* `kicad-cli pcb drc --refill-zones` refills zones first; without it the report can use stale pour fills.

## Rules of the road (learned on the gauge board)

* **Check for the PCB editor before writing a board file.** A `~<name>.kicad_pcb.lck` next to the file means it is open.
  Also compare a hash of the file with your last write: the owner edits the layout by hand between your steps (they moved
  parts, resized the board, added a logo). Back the file up first. Never silently overwrite their placement.
* The owner wants **placement reviewed first, routing only after an explicit go**.
* They notice cosmetic problems: messy or ambiguous silkscreen labels, and "unnecessary" vias (stitching vias under a
  module). Look at a render of both sides before calling a layout done.
* pcbnew API notes: `pads = fp.Pads()` then iterate it (do not wrap it in `list()`); `fp.Remove(pad)` works;
  net names from the netlist start with `/` (`/+3V3`, `/SDA`); a footprint's `path` is the schematic symbol UUID, which is
  what keeps "Update PCB from Schematic" from duplicating parts. Do not name a script `inspect.py` (it shadows the stdlib).
* The ADS122C04 library footprint still carries four 2.5 mm mounting holes. On the gauge board they were removed from the
  BOARD only (`tools/layout/remove_pads.py`); "Update footprints from library" would restore them.
* `lib_footprint_mismatch` DRC warnings ("local override") are cosmetic: text moved or fields edited on a footprint.
* `kicad-cli pcb export gerbers` writes a date into every file header, so re-exports differ byte-for-byte but not in content.

## Fabrication settings used (PCBWay, 2 layers)

1.6 mm FR4, 1 oz copper, min track/space 6/6 mil (0.1524 mm), min drill 0.3 mm, copper-to-edge 0.3 mm. Default net class:
0.25 mm track, 0.2 mm clearance, 0.6/0.3 mm via (`tools/layout/set_pcbway_rules.py` writes these into the `.kicad_pro`).
Stay inside 100 x 100 mm (PCBWay's cheapest quote tier). Everything on the top face, all connectors vertical 0.1 in
headers, M3 holes (3.2 mm) 4 mm in from each corner, copper pour kept 3.25 mm (radius) from each hole for the screw head.
Reference text 0.8 mm, horizontal. PCBWay's own help for the board-type options (single / panel by customer / panel by
PCBWay) is at pcbway.com/helpcenter/ordering_parameter_instruction/Board_type.html.

## Gauge board as built (rev A)

* 54.22 x 49.60 mm, 3 mm corner radius, M3 holes 46 x 41.5 mm apart. Layout (owner's final, hand-adjusted): loom J1/J2 as
  horizontal rows at the top left; C1, C2, U1 (LDO), C3, C4 and the test points down the left; R5/R6 (completion pair)
  vertical at the lower left; ADS122C04 breakouts U2 above U3, both rotated 180 degrees (digital row on top); R2/C5/R1
  between the modules and R4/C6/R3 below U3 (the optional filter positions); gauge headers J4 above J3 on the right (2x3
  each, rows V V / SIG SIG / GND GND). Logo and "STRAIN GAUGE BREAKOUT" text are on the back silkscreen.
* Routing (all scripted): horizontals on F.Cu, verticals on B.Cu; +3V3 is a trunk from the LDO to both ADCs and J3/J4;
  SDA/SCL run as a two-wire bus on the left; GND is a pour on both layers with 21 stitching vias outside the modules.
* **ADS_REF**: the two legs from the R5/R6 midpoint to R2.1 and R4.1 are equal (12.05 mm each).
* **SIG paths are not matched**: SIG1 4.7 mm, SIG2 37.2 mm, because J4 sits above J3 while R3 is at the bottom. Accepted by
  the owner (DC bridge signal); swapping J3/J4 or moving R3/C6 nearer J4 would fix it on a respin.
* Fab: 103 plated holes (0.3, 0.75, 0.8, 1.0 mm) and 4 non-plated M3 holes (3.2 mm).

## Next: the main board

* Brief: `../docs/PCB_BRIEF.md` (section 0 decisions, section 7 placement guidelines). Pico Plus 2 is 51 x 21 mm, the Pololu is
  6.1 mm tall, USB-C at the top, supply connector and Pololu at one end, loom and IMU headers at the Pico end.
* Main-board loom J2 must keep the order GND, +5V, SDA, SCL (same as gauge J1) and 3.3 V logic on SDA/SCL.
* Big supply paths: `+12V`, `VSERVO` (8.4 V, 5 A rail) and returns need wide traces or pours. Do not let the default 0.25 mm
  net class touch them.
* Lay it out in the SAME release folder (`releases/20261026-2252-rev-a/hastadaq/`) next to the gauge board.

## Faster routing for future boards

The gauge board (about 50 connections) took many iterations of hand-planned coordinates. The main board has far more
(Pico, six servo plugs, four SPI encoder ports, trigger and soft-stop circuits), so scripting every track by hand will not scale.
[KiCadRoutingTools](https://github.com/drandyhaas/KiCadRoutingTools) (MIT, Rust-accelerated A* router, KiCad 9/10, plugin and
CLI, plane pours, power-net widths, DRC and connectivity checkers) looks like a good fit **for the non-critical nets**.
This was judged from its README only; it has not been run here. Suggested trial: copy the main board, place parts by hand
first, route GND as a pour, let the tool route the logic nets, hand-route power and anything noise-critical, then run
`kicad-cli pcb drc --refill-zones` and review in KiCad. Install from KiCad's Plugin and Content Manager or build from source
rather than running an unvetted binary. Known limits per its README: no push-and-shove, no blind/buried vias; behaviour on a
2-layer through-hole board is not documented, so test before trusting.
