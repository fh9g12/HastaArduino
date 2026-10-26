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
