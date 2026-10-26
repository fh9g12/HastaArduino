"""Publish a snapshot of the generated schematics into a new, unique folder to start PCB layout in.

    py kicad/tools/publish.py                  # snapshot as kicad/releases/<date-time>/
    py kicad/tools/publish.py --label rev-a    # kicad/releases/<date-time>-rev-a/
    py kicad/tools/publish.py --regenerate     # re-run both generators first, then snapshot
    py kicad/tools/publish.py --force          # publish even if ERC reports violations

Each release folder is self-contained and mirrors the working layout, so the relative library paths
(the gauge board's ${KIPRJMOD}/../hastadaq/HastaDAQ.pretty) keep working:

    kicad/releases/<name>/hastadaq/     main board project, schematic, symbol + footprint libraries, PDF/PNG, netlist
    kicad/releases/<name>/gaugeboard/   gauge board project, schematic, libraries, PDF/PNG, netlist
    kicad/releases/<name>/docs/         the PCB briefs and parts list as they were at publish time
    kicad/releases/<name>/PUBLISHED.md  date, git commit (and whether the tree was dirty), ERC result

Start the .kicad_pcb inside the release folder, next to its schematic. A release is never overwritten
or reused: when the schematic changes (edit a generator, re-run it, publish again), publish a NEW folder
and start layout again there. Once a .kicad_pcb exists in a release, never re-run a generator over it:
edit that release's schematic in KiCad instead.
"""
import argparse
import datetime
import pathlib
import shutil
import subprocess
import tempfile
import sys

TOOLS = pathlib.Path(__file__).resolve().parent
KICAD = TOOLS.parent
REPO = KICAD.parent
BOARDS = ("hastadaq", "gaugeboard")
DOCS = ("PCB_BRIEF.md", "PCB_BRIEF_GAUGE.md", "PARTS_TO_SELECT.md")
SKIP = shutil.ignore_patterns("*.kicad_prl", "*.kicad_pcb", "*-backups", "fp-info-cache",
                              "*.lck", "~*", "*.bak", "_autosave-*", "*.pdf", "*.png")


START_HERE = """# Start here: PCB layout for release {name}

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
"""


def find_kicad_cli():
    exe = shutil.which("kicad-cli")
    if exe:
        return exe
    roots = [pathlib.Path(p) for p in (
        pathlib.Path.home() / "AppData/Local/Programs/KiCad", "C:/Program Files/KiCad") if pathlib.Path(p).exists()]
    for root in roots:
        for cand in sorted(root.glob("*/bin/kicad-cli.exe"), reverse=True):
            return str(cand)
    sys.exit("kicad-cli not found (add KiCad's bin folder to PATH)")


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def git(*args):
    r = run(["git", "-C", REPO, *args])
    return r.stdout.strip() if r.returncode == 0 else ""


def unlock_pdf(path):
    """kicad-cli PDFs carry a permissions lock; strip it if pikepdf is installed."""
    try:
        import pikepdf
    except ImportError:
        return False
    tmp = path.with_suffix(".unlocked.pdf")
    with pikepdf.open(path, password="") as pdf:
        pdf.save(tmp, encryption=False)
    tmp.replace(path)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", help="short suffix for the folder name, e.g. rev-a")
    ap.add_argument("--regenerate", action="store_true", help="re-run both generators before snapshotting")
    ap.add_argument("--force", action="store_true", help="publish even if ERC reports violations")
    args = ap.parse_args()

    if args.regenerate:
        for gen in ("generate_hastadaq_sch.py", "generate_gauge_sch.py"):
            r = run([sys.executable, TOOLS / gen])
            if r.returncode:
                sys.exit(f"{gen} failed:\n{r.stdout}{r.stderr}")
            print(f"regenerated with {gen}")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    name = stamp + (f"-{args.label}" if args.label else "")
    dest = KICAD / "releases" / name
    if dest.exists():
        sys.exit(f"{dest} already exists: releases are never overwritten (wait a minute or use --label)")

    cli = find_kicad_cli()
    erc = {}
    for b in BOARDS:   # gate on ERC before copying anything
        sch = KICAD / b / f"{b}.kicad_sch"
        rpt = pathlib.Path(tempfile.gettempdir()) / f"hastadaq_erc_{b}.rpt"
        run([cli, "sch", "erc", "--output", rpt, "--format", "report", "--severity-all", sch])
        text = rpt.read_text(encoding="utf-8", errors="replace") if rpt.exists() else ""
        rpt.unlink(missing_ok=True)
        line = next((l.strip() for l in text.splitlines() if "ERC messages" in l), "ERC did not run")
        erc[b] = line
        print(f"{b}: {line}")
        if "0  Errors 0  Warnings 0" not in line and not args.force:
            sys.exit(f"ERC is not clean for {b}; fix it or pass --force")

    for b in BOARDS:
        shutil.copytree(KICAD / b, dest / b, ignore=SKIP)
        sch = dest / b / f"{b}.kicad_sch"
        run([cli, "sch", "export", "netlist", "--format", "kicadsexpr", "--output", dest / b / f"{b}.net", sch])
        run([cli, "sch", "export", "pdf", "--output", dest / b / f"{b}.pdf", sch])
        (dest / b / f"{b}.kicad_prl").unlink(missing_ok=True)   # kicad-cli writes one; per-user state
        unlocked = unlock_pdf(dest / b / f"{b}.pdf")
        if not unlocked:
            print(f"note: pikepdf not installed, {b}.pdf keeps kicad-cli's permissions lock")
    (dest / "docs").mkdir()
    for d in DOCS:
        shutil.copy2(REPO / "docs" / d, dest / "docs" / d)

    wiring = REPO / "wiring" / "gauge-loom.yml"
    if wiring.exists():
        (dest / "wiring").mkdir()
        shutil.copy2(wiring, dest / "wiring" / wiring.name)
    (dest / "START_HERE.md").write_text(START_HERE.format(name=name), encoding="utf-8")

    commit = git("rev-parse", "--short", "HEAD") or "unknown"
    dirty = "dirty (uncommitted changes in the working tree)" if git("status", "--porcelain") else "clean"
    (dest / "PUBLISHED.md").write_text(
        f"# Published schematic snapshot {name}\n\n"
        f"* Published: {datetime.datetime.now().isoformat(timespec='seconds')}\n"
        f"* Git commit: `{commit}`, working tree {dirty}\n"
        + "".join(f"* ERC {b}: {erc[b]}\n" for b in BOARDS)
        + "\n"
        "Start the PCBs here: `hastadaq/hastadaq.kicad_pcb` and `gaugeboard/gaugeboard.kicad_pcb`, using\n"
        "Tools > Update PCB from Schematic. This folder is a snapshot: do not re-run a generator over it. To change\n"
        "the schematic after layout has begun, edit the .kicad_sch here in KiCad; to start over from regenerated\n"
        "sources, run `py kicad/tools/publish.py` again and lay out in the NEW folder.\n"
        "`docs/` holds the briefs as they were at publish time. The netlists (`*.net`) can be diffed between\n"
        "releases to see exactly what changed.\n", encoding="utf-8")
    print(f"published {dest.relative_to(REPO)}")


if __name__ == "__main__":
    main()
