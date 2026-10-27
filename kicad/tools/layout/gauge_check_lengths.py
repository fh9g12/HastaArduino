"""GAUGE BOARD: print routed path lengths for the ADS_REF legs, SIG runs and A0/A1 links (read-only).

    python.exe gauge_check_lengths.py gaugeboard.kicad_pcb

Pad names and the ADS_REF junction (41.9, 64.75) are hard-coded for the as-built layout. Result at order
time: REF 12.05 mm to each of R2.1 and R4.1 (matched); SIG1 4.7 mm, SIG2 37.2 mm (not matched, accepted:
DC bridge signal).
"""
import pcbnew, sys, heapq, math
from pcbnew import ToMM
b = pcbnew.LoadBoard(sys.argv[1])
def key(p): return (round(ToMM(p.x), 3), round(ToMM(p.y), 3))
def path_len(netname, a, b_):
    adj = {}
    def add(u, v, w):
        adj.setdefault(u, []).append((v, w)); adj.setdefault(v, []).append((u, w))
    for t in b.GetTracks():
        if str(t.GetNetname()) != netname or t.GetClass() == "PCB_VIA": continue
        u, v = key(t.GetStart()), key(t.GetEnd())
        add(u, v, math.dist(u, v))
    # tracks end exactly at pad centres or on other tracks' endpoints; also connect endpoint to a track it lies on
    segs = [(key(t.GetStart()), key(t.GetEnd())) for t in b.GetTracks() if str(t.GetNetname()) == netname and t.GetClass() != "PCB_VIA"]
    pts = list(adj.keys())
    for f in b.GetFootprints():
        for p in f.Pads():
            if str(p.GetNetname()) == netname: pts.append(key(p.GetPosition()))
    for p in pts:
        for (s, e) in segs:
            if p in (s, e): continue
            d = s, e
            L = math.dist(s, e)
            if L == 0: continue
            u = ((p[0]-s[0])*(e[0]-s[0]) + (p[1]-s[1])*(e[1]-s[1])) / L**2
            if 0 < u < 1 and math.dist(p, (s[0]+u*(e[0]-s[0]), s[1]+u*(e[1]-s[1]))) < 0.01:
                q1 = s; add(p, s, math.dist(p, s)); add(p, e, math.dist(p, e))
    dist = {a: 0}; pq = [(0, a)]
    while pq:
        d, u = heapq.heappop(pq)
        if d > dist.get(u, 1e9): continue
        for v, w in adj.get(u, []):
            if d + w < dist.get(v, 1e9): dist[v] = d + w; heapq.heappush(pq, (d + w, v))
    return dist.get(b_)
def pad(ref, num):
    for f in b.GetFootprints():
        if f.GetReference() == ref:
            for p in f.Pads():
                if p.GetNumber() == str(num): return key(p.GetPosition())
J = (41.9, 64.75)
print("REF  junction->R2.1 : %.2f mm" % path_len("/ADS_REF", J, pad("R2", 1)))
print("REF  junction->R4.1 : %.2f mm" % path_len("/ADS_REF", J, pad("R4", 1)))
print("SIG1 R1.1 -> J3.3   : %.2f mm" % path_len("/ADS1_SIG", pad("R1", 1), pad("J3", 3)))
print("SIG2 R3.1 -> J4.3   : %.2f mm" % path_len("/ADS2_SIG", pad("R3", 1), pad("J4", 3)))
print("A0-1 U2.7 -> R1.2   : %.2f mm" % path_len("/ADS1_A0", pad("U2", 7), pad("R1", 2)))
print("A0-2 U3.7 -> R3.2   : %.2f mm" % path_len("/ADS2_A0", pad("U3", 7), pad("R3", 2)))
print("A1-1 U2.8 -> R2.2   : %.2f mm" % path_len("/ADS1_A1", pad("U2", 8), pad("R2", 2)))
print("A1-2 U3.8 -> R4.2   : %.2f mm" % path_len("/ADS2_A1", pad("U3", 8), pad("R4", 2)))
