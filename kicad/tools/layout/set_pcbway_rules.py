"""PCBWay 2-layer design rules (6/6 mil, 0.3 mm drill) into a .kicad_pro. Usage: set_rules.py <file.kicad_pro>"""
import json
import sys

p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
r = d["board"]["design_settings"]["rules"]
r["min_clearance"] = 0.1524
r["min_track_width"] = 0.1524
r["min_through_hole_diameter"] = 0.3
r["min_via_diameter"] = 0.6
r["min_copper_edge_clearance"] = 0.3
r["min_silk_clearance"] = 0.15
c = d["net_settings"]["classes"][0]
c["clearance"] = 0.2
c["track_width"] = 0.25
c["via_diameter"] = 0.6
c["via_drill"] = 0.3
json.dump(d, open(p, "w", encoding="utf-8", newline="\n"), indent=2)
open(p, "a").write("\n")
print("rules set in", p)
