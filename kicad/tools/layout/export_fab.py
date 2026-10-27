"""Export PCBWay-ready fabrication files for a board with kicad-cli and zip them.

    py kicad/tools/layout/export_fab.py <board.kicad_pcb> [output_dir]

Writes <output_dir>/gerbers/ (7 Gerber layers + job file + PTH/NPTH Excellon drill files + PDF drill maps) and
<output_dir>/<board>_gerbers.zip (Gerbers and .drl only, which is what you upload). output_dir defaults to a
`fab/` folder next to the board. Zones are refilled first. Close the PCB editor first so the saved file is current.
This is exactly what was run for the gauge board (rev A, ordered 2026-10-27).
"""
import pathlib
import shutil
import subprocess
import sys
import zipfile

LAYERS = "F.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,Edge.Cuts"
UPLOAD_EXT = {".gtl", ".gbl", ".gts", ".gbs", ".gto", ".gbo", ".gm1", ".drl"}


def find_kicad_cli():
    exe = shutil.which("kicad-cli")
    if exe:
        return exe
    for root in (pathlib.Path.home() / "AppData/Local/Programs/KiCad", pathlib.Path("C:/Program Files/KiCad")):
        if root.exists():
            for cand in sorted(root.glob("*/bin/kicad-cli.exe"), reverse=True):
                return str(cand)
    sys.exit("kicad-cli not found (add KiCad's bin folder to PATH)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    board = pathlib.Path(sys.argv[1]).resolve()
    out = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else board.parent / "fab"
    if board.with_name(f"~{board.name}.lck").exists():
        sys.exit("the PCB editor has this board open (lock file present); close it first")
    gerbers = out / "gerbers"
    gerbers.mkdir(parents=True, exist_ok=True)
    cli = find_kicad_cli()
    subprocess.run([cli, "pcb", "export", "gerbers", "--output", f"{gerbers}/", "--layers", LAYERS,
                    "--check-zones", "--subtract-soldermask", str(board)], check=True, capture_output=True)
    subprocess.run([cli, "pcb", "export", "drill", "--output", f"{gerbers}/", "--format", "excellon",
                    "--excellon-separate-th", "--excellon-units", "mm", "--drill-origin", "absolute",
                    "--generate-map", "--map-format", "pdf", str(board)], check=True, capture_output=True)
    zpath = out / f"{board.stem}_gerbers.zip"
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(gerbers.iterdir()):
            if f.suffix.lower() in UPLOAD_EXT:
                z.write(f, f.name)
    print("wrote", zpath)
    for f in sorted(gerbers.iterdir()):
        if f.suffix.lower() == ".drl":
            lines = f.read_text().splitlines()
            tools = [l for l in lines if l.startswith("T") and "C" in l]
            hits = sum(1 for l in lines if l.startswith("X"))
            print(f"  {f.name}: {hits} holes, tools {' '.join(tools)}")


if __name__ == "__main__":
    main()
