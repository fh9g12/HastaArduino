"""Compare netlist pin numbers with footprint pad numbers for every part on a board (read-only).

    python.exe check_pad_nets.py <board.kicad_pcb> <board.net>

Run it after building a board from a netlist: a part whose schematic pin numbers do not match its footprint pad numbers
gets NO nets (its pads show no ratsnest). This caught D1-D4 on the main board (symbol pins A/K vs footprint pads 1/2).
Prints one line per mismatching part and "parts with a mismatch: 0" when everything lines up.
"""
import re
import sys
import pcbnew

pcb, net = sys.argv[1], sys.argv[2]
t = open(net, encoding="utf-8").read()
pins = {}
for m in re.finditer(r'\(net\s+\(code "\d+"\)\s+\(name "([^"]+)"\)(.*?)\n\t\t\)', t, re.S):
    for r, p in re.findall(r'\(ref "([^"]+)"\)\s+\(pin "([^"]+)"\)', m.group(2)):
        pins.setdefault(r, {})[p] = m.group(1)

b = pcbnew.LoadBoard(pcb)
bad = 0
for fp in b.GetFootprints():
    ref = fp.GetReference()
    if ref not in pins:
        continue
    pad_nums = {p.GetNumber() for p in fp.Pads() if p.GetNumber()}
    missing = sorted(set(pins[ref]) - pad_nums)            # netlist pins with no pad
    unnetted = sorted(n for n in pad_nums if not any(p.GetNumber() == n and str(p.GetNetname()) for p in fp.Pads()))
    if missing or unnetted:
        bad += 1
        print("%-4s netlist pins without a pad: %-14s pads without a net: %s" % (ref, missing, unnetted))
print("parts with a mismatch:", bad)
