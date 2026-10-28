"""Small two-layer grid router (octilinear A*), plain Python + numpy. No pcbnew dependency: it works on millimetre
coordinates relative to the board's top-left corner, so a board-specific script feeds it pads, keep-outs and nets and
turns its result back into tracks and vias.

Model
  * Cells are `pitch` mm apart (0.1). A track of width w may have its centre in a cell only if no FOREIGN copper
    (another net's pad, track, via, or a hard keep-out) is closer than clearance + w/2 (+ a small margin).
  * Foreign-copper clearance is pre-computed per track-width class with exact distances to each shape (circle,
    capsule, rectangle), stored as an owner id per cell: 0 free, n = only net n is near, MULTI = several nets near.
    A cell is blocked for net n if its owner is neither 0 nor n.
  * One extra class for vias (copper diameter via_d) is tested on both layers before a layer change.
  * Through-hole pads exist on both layers, SMD pads on one. Moves: 8 directions on a layer (cost 1 / 1.414, with a
    penalty for the non-preferred direction: top prefers horizontal, bottom vertical) plus via moves.
  * A net is routed as a tree: start from its first pad (or its already-existing copper), repeatedly A* from the whole
    tree to the nearest unconnected pad. Routed copper is marked immediately so later nets avoid it.
Limits: no rip-up and reroute, no push-and-shove; result is checked by KiCad DRC, which is the real judge.
"""
import heapq
import math

import numpy as np

HARD = 30000          # owner id of keep-outs (never equal to a routed net id)
MULTI = -2


class GridRouter:
    def __init__(self, width_mm, height_mm, track_widths, pitch=0.1, clearance=0.2, via_d=0.6, margin=0.03):
        self.p = pitch
        self.nx = int(math.ceil(width_mm / pitch)) + 1
        self.ny = int(math.ceil(height_mm / pitch)) + 1
        self.clear = clearance
        self.margin = margin
        self.via_d = via_d
        self.widths = sorted(set(track_widths))
        self.classes = self.widths + [via_d]              # last class = via copper
        self.owner = [[np.zeros((self.ny, self.nx), np.int16) for _ in range(2)] for _ in self.classes]
        self.X = (np.arange(self.nx) * pitch)[None, :]
        self.Y = (np.arange(self.ny) * pitch)[:, None]
        self.no_via = np.zeros((self.ny, self.nx), bool)  # cells where no via may be centred (hole-to-hole spacing)
        self.log = []

    def block_via(self, cx, cy, r):
        """No via centre within r mm of (cx, cy), on either layer (drilled holes need hole-to-hole spacing)."""
        ix0, ix1 = max(int((cx - r) / self.p) - 1, 0), min(int((cx + r) / self.p) + 2, self.nx)
        iy0, iy1 = max(int((cy - r) / self.p) - 1, 0), min(int((cy + r) / self.p) + 2, self.ny)
        if ix1 > ix0 and iy1 > iy0:
            self.no_via[iy0:iy1, ix0:ix1] |= np.hypot(self.X[:, ix0:ix1] - cx, self.Y[iy0:iy1, :] - cy) < r

    # ------------------------------------------------------------------ marking copper / keep-outs
    def _dist(self, shape, ix0, ix1, iy0, iy1):
        X = self.X[:, ix0:ix1]
        Y = self.Y[iy0:iy1, :]
        kind = shape[0]
        if kind == "circle":
            _, cx, cy, r = shape
            return np.hypot(X - cx, Y - cy) - r
        if kind == "seg":                                 # capsule: segment p-q with radius r
            _, x0, y0, x1, y1, r = shape
            dx, dy = x1 - x0, y1 - y0
            L2 = dx * dx + dy * dy
            if L2 < 1e-12:
                return np.hypot(X - x0, Y - y0) - r
            t = np.clip(((X - x0) * dx + (Y - y0) * dy) / L2, 0.0, 1.0)
            return np.hypot(X - (x0 + t * dx), Y - (y0 + t * dy)) - r
        if kind == "rect":
            _, x0, y0, x1, y1 = shape
            return np.hypot(np.maximum(np.maximum(x0 - X, X - x1), 0.0), np.maximum(np.maximum(y0 - Y, Y - y1), 0.0))
        raise ValueError(kind)

    @staticmethod
    def _bbox(shape):
        kind = shape[0]
        if kind == "circle":
            _, cx, cy, r = shape
            return cx - r, cy - r, cx + r, cy + r
        if kind == "seg":
            _, x0, y0, x1, y1, r = shape
            return min(x0, x1) - r, min(y0, y1) - r, max(x0, x1) + r, max(y0, y1) + r
        _, x0, y0, x1, y1 = shape
        return x0, y0, x1, y1

    def mark(self, shape, net, layers):
        """Record copper (or a keep-out, net=HARD) of `net` on the given layers for every width class."""
        bx0, by0, bx1, by1 = self._bbox(shape)
        for ci, w in enumerate(self.classes):
            d = self.clear + w / 2 + self.margin
            ix0 = max(int((bx0 - d) / self.p) - 1, 0)
            ix1 = min(int((bx1 + d) / self.p) + 2, self.nx)
            iy0 = max(int((by0 - d) / self.p) - 1, 0)
            iy1 = min(int((by1 + d) / self.p) + 2, self.ny)
            if ix1 <= ix0 or iy1 <= iy0:
                continue
            m = self._dist(shape, ix0, ix1, iy0, iy1) < d
            for l in layers:
                a = self.owner[ci][l][iy0:iy1, ix0:ix1]
                a[...] = np.where(m, np.where((a == 0) | (a == net), net, MULTI), a)

    def mark_track(self, net, layer, pts, width):
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            self.mark(("seg", x0, y0, x1, y1, width / 2), net, [layer])

    def mark_via(self, net, x, y, hole_d=0.3, min_hole_gap=0.3):
        self.mark(("circle", x, y, self.via_d / 2), net, [0, 1])
        self.block_via(x, y, hole_d + min_hole_gap + 0.1)       # centre-to-centre between two via holes

    def block_outside_rounded_rect(self, w_mm, h_mm, corner_r, margin):
        """Hard-block cells closer than margin + w/2 to the board edge (rounded rectangle 0..w x 0..h)."""
        cx, cy = w_mm / 2, h_mm / 2
        qx = np.abs(self.X - cx) - (cx - corner_r)
        qy = np.abs(self.Y - cy) - (cy - corner_r)
        sdf = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - corner_r
        inside = -sdf                                       # distance to the edge for points inside (<0 outside)
        for ci, w in enumerate(self.classes):
            blocked = inside < (margin + w / 2)
            for l in (0, 1):
                a = self.owner[ci][l]
                a[blocked] = MULTI

    # ------------------------------------------------------------------ routing
    def _masks(self, net, ci):
        out = []
        for l in (0, 1):
            o = self.owner[ci][l]
            out.append(bytearray(((o != 0) & (o != net)).ravel().tobytes()))
        return out

    def ascii_map(self, x, y, r, width, net, step=2):
        """Debug view of what is blocked for `net` around (x, y), top layer above bottom layer ('#' blocked, '.' free)."""
        ci = self.classes.index(width)
        cx, cy = self._cell(x, y)
        n = int(r / self.p)
        out = []
        for l in (0, 1):
            out.append("layer %d (centre %.1f,%.1f, 1 char = %.1f mm)" % (l, x, y, step * self.p))
            o = self.owner[ci][l]
            for iy in range(max(cy - n, 0), min(cy + n, self.ny), step):
                row = ""
                for ix in range(max(cx - n, 0), min(cx + n, self.nx), step):
                    v = o[iy][ix]
                    row += "+" if (ix, iy) == (cx, cy) else ("." if v in (0, net) else "#")
                out.append(row)
        return "\n".join(out)

    def _cell(self, x, y):
        return int(round(x / self.p)), int(round(y / self.p))

    def route_net(self, net, width, pads, existing=(), via_cost=14.0, max_expand=900000):
        """pads: list of dicts {x, y, layers:[0,1] or [0]}. existing: list of (layer, [(x,y),...]) already-placed
        copper of this net (counts as the start of the tree). Returns dict(tracks=[(layer, pts, width)], vias=[(x,y)],
        failed=[pads that could not be connected])."""
        ci = self.classes.index(width)
        blk = self._masks(net, ci)
        vclass = len(self.classes) - 1
        o0, o1 = self.owner[vclass]
        via_ok = bytearray((((o0 == 0) | (o0 == net)) & ((o1 == 0) | (o1 == net)) & ~self.no_via).ravel().tobytes())
        nx, ny, p = self.nx, self.ny, self.p
        plane = nx * ny

        def node(l, ix, iy):
            return l * plane + iy * nx + ix

        tree = {}                                           # node -> True
        def add_cell(l, ix, iy):
            tree[node(l, ix, iy)] = True

        def add_polyline(layer, pts):
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                n = max(int(math.hypot(x1 - x0, y1 - y0) / p), 1)
                for k in range(n + 1):
                    ix, iy = self._cell(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n)
                    add_cell(layer, ix, iy)

        def seg_dist(px, py, a, b):
            (x0, y0), (x1, y1) = a, b
            dx, dy = x1 - x0, y1 - y0
            L2 = dx * dx + dy * dy
            t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / L2))
            return math.hypot(px - (x0 + t * dx), py - (y0 + t * dy))

        for layer, pts in existing:
            add_polyline(layer, pts)
        connected, todo = [], []
        for pd in pads:
            near = any(seg_dist(pd["x"], pd["y"], a, b) <= 0.35 for layer, pts in existing for a, b in zip(pts, pts[1:]))
            (connected if near else todo).append(pd)
        if not connected and todo:
            first = todo.pop(0)
            connected.append(first)
        for pd in connected:
            ix, iy = self._cell(pd["x"], pd["y"])
            for l in pd["layers"]:
                add_cell(l, ix, iy)

        result = dict(tracks=[], vias=[], failed=[])
        while todo:
            # nearest unconnected pad to any connected pad
            tgt = min(todo, key=lambda t: min(math.hypot(t["x"] - c["x"], t["y"] - c["y"]) for c in connected))
            todo.remove(tgt)
            tx, ty = self._cell(tgt["x"], tgt["y"])
            goals = {node(l, tx, ty) for l in tgt["layers"]}
            path = self._astar(tree, goals, tx, ty, blk, via_ok, via_cost, max_expand)
            if path is None:
                result["failed"].append(tgt)
                continue
            self._emit(path, net, width, pads_hint=(connected + [tgt]), result=result, tree=tree)
            connected.append(tgt)
        return result

    def _astar(self, sources, goals, gx, gy, blk, via_ok, via_cost, max_expand):
        nx, ny = self.nx, self.ny
        plane = nx * ny
        inf = float("inf")
        g = {}
        prev = {}
        heap = []
        SQ = 1.41421356
        # (dx, dy, cost, is_horizontal, is_vertical)
        moves = ((1, 0, 1.0, 1), (-1, 0, 1.0, 1), (0, 1, 1.0, 2), (0, -1, 1.0, 2),
                 (1, 1, SQ, 0), (1, -1, SQ, 0), (-1, 1, SQ, 0), (-1, -1, SQ, 0))
        PEN = 1.35

        def h(x, y):
            dx, dy = abs(x - gx), abs(y - gy)
            return (dx + dy) + (SQ - 2) * min(dx, dy)

        for s in sources:
            g[s] = 0.0
            l, r = divmod(s, plane)
            y, x = divmod(r, nx)
            heapq.heappush(heap, (h(x, y), 0.0, s))
        expanded = 0
        while heap:
            f, gc, n = heapq.heappop(heap)
            if gc > g.get(n, inf):
                continue
            if n in goals:
                out = [n]
                while n in prev:
                    n = prev[n]
                    out.append(n)
                out.reverse()
                return out
            expanded += 1
            if expanded > max_expand:
                return None
            l, r = divmod(n, plane)
            y, x = divmod(r, nx)
            bl = blk[l]
            for dx, dy, c, axis in moves:
                x2, y2 = x + dx, y + dy
                if x2 < 0 or y2 < 0 or x2 >= nx or y2 >= ny:
                    continue
                if bl[y2 * nx + x2]:
                    continue
                if axis == 0 and (bl[y * nx + x2] or bl[y2 * nx + x]):
                    continue                                 # no cutting a diagonal across a blocked corner
                if (l == 0 and axis == 2) or (l == 1 and axis == 1):
                    c *= PEN
                n2 = l * plane + y2 * nx + x2
                g2 = gc + c
                if g2 < g.get(n2, inf):
                    g[n2] = g2
                    prev[n2] = n
                    heapq.heappush(heap, (g2 + h(x2, y2), g2, n2))
            if via_ok[y * nx + x]:
                l2 = 1 - l
                n2 = l2 * plane + y * nx + x
                if not blk[l2][y * nx + x]:
                    g2 = gc + via_cost
                    if g2 < g.get(n2, inf):
                        g[n2] = g2
                        prev[n2] = n
                        heapq.heappush(heap, (g2 + h(x, y), g2, n2))
        return None

    def _emit(self, path, net, width, pads_hint, result, tree):
        nx, ny, p = self.nx, self.ny, self.p
        plane = nx * ny
        cells = []
        for n in path:
            l, r = divmod(n, plane)
            y, x = divmod(r, nx)
            cells.append((l, x, y))
            tree[n] = True
        # split into per-layer runs, merging collinear steps
        runs, cur = [], [cells[0]]
        for c in cells[1:]:
            if c[0] != cur[-1][0]:
                runs.append(cur)
                cur = [c]
                result["vias"].append((c[1] * p, c[2] * p))
            else:
                cur.append(c)
        runs.append(cur)
        for run in runs:
            layer = run[0][0]
            pts = [(run[0][1] * p, run[0][2] * p)]
            for a, b, c in zip(run, run[1:], run[2:]):
                if (b[1] - a[1], b[2] - a[2]) != (c[1] - b[1], c[2] - b[2]):
                    pts.append((b[1] * p, b[2] * p))
            pts.append((run[-1][1] * p, run[-1][2] * p))
            if len(pts) >= 2 and pts[0] != pts[-1]:
                result["tracks"].append((layer, pts, width))
                self.mark_track(net, layer, pts, width)
        for (x, y) in result["vias"][-(len(runs) - 1):] if len(runs) > 1 else []:
            self.mark_via(net, x, y)
