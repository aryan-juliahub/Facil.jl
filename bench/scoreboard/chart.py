#!/usr/bin/env python3
"""Benchmark charts for the README and docs (Python 3 standard library only).

    python3 bench/scoreboard/chart.py data     # results/<runs> + rows.json -> chart_data.csv
    python3 bench/scoreboard/chart.py          # chart_data.csv -> docs/src/assets/bench-*.svg

`data` needs the local `results/` directories (not committed); rendering needs only
`chart_data.csv`. Each SVG comes in a light and a dark variant for `<picture>`.
"""
import csv
import json
import math
import os
import re
import sys
from html import escape

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CSV_PATH = os.path.join(HERE, "chart_data.csv")
ASSETS = os.path.join(REPO, "docs", "src", "assets")

# Later runs replace earlier ones row by row: the full run of 26 Nov 2026, then the
# rerun of every row whose verdict changed against the previous published numbers.
SOURCES = [
    "20261126-212620",
    "20261126-234001",
]

DATE = "26 Nov 2026"

# Rows drawn in the throughput chart, in this order, with their short labels.
HEADLINE = [
    ("A1", "Tiny reply, 1 core"),
    ("A2", "150-byte JSON, 1 core"),
    ("A3", "POST echo"),
    ("A4", "100 KB response"),
    ("A19b", "12 request headers"),
    ("A20c", "Pipelining, depth 16"),
    ("A16", "Keep-alive, 1,000 connections"),
    ("A17", "Keep-alive, 10,000 connections"),
    ("2", "Tiny JSON, 4 cores (Node cluster)"),
    ("3", "Tiny JSON, 8 cores (Node cluster)"),
    ("1", "CPU-bound, 8 cores (Node cluster)"),
    ("4", "Task handler, 2 threads"),
    ("17a", "Handler sleeps 1 ms, 100 connections"),
    ("A27", "HTTPS JSON, keep-alive"),
    ("A13a", "TLS handshakes, ECDSA"),
    ("A12b", "Upload 64 KB"),
    ("A11", "gzip, 100 KB JSON"),
    ("27", "Streamed gzip, 100 KB JSON"),
    ("19a", "Build a 1 KB JSON response"),
    ("A29", "WebSocket echo 64 B (uWS)"),
    ("7-c10", "WebSocket echo 256 KB, 10 conns (uWS)"),
    ("7-c100", "WebSocket echo 256 KB, 100 conns (uWS)"),
    ("A14", "WS broadcast, 1k subs x 1 kHz (uWS)"),
]

FIELDS = ["row", "name", "metric", "better", "facil", "facil_min", "facil_max", "node",
          "node_min", "node_max", "opponent", "ratio", "verdict", "flags", "run", "label"]


def parse_cell(cell):
    m = re.match(r"\s*([\d.,]+)(?:\s*\(([\d.,]+)[–-]([\d.,]+)\))?", cell)
    if not m:
        return None
    vals = [float(v.replace(",", "")) if v else None for v in m.groups()]
    if vals[1] is None:
        vals[1] = vals[2] = vals[0]
    return vals


def build_data():
    spec = {r["id"]: r for r in json.load(open(os.path.join(HERE, "rows.json")))["rows"]}
    labels = dict(HEADLINE)
    data = {}
    for run in SOURCES:
        for line in open(os.path.join(HERE, "results", run, "table.md")):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 11 or cells[0] in ("row", "---") or cells[0].startswith("-"):
                continue
            facil, node = parse_cell(cells[3]), parse_cell(cells[4])
            if facil is None or node is None:
                continue
            rid = cells[0]
            s = spec[rid]
            higher = s["better"] == "higher"
            if facil[0] == node[0]:
                ratio = 1.0
            else:
                ratio = facil[0] / node[0] if higher else node[0] / facil[0]
            target = s.get("target", 1.0)
            verdict = "PASS" if ratio >= target else ("EXCEPTION" if "exception" in s else "FAIL")
            data[rid] = dict(
                row=rid, name=cells[1], metric=s["metric"], better=s["better"],
                facil=facil[0], facil_min=facil[1], facil_max=facil[2],
                node=node[0], node_min=node[1], node_max=node[2],
                opponent=cells[8], ratio=f"{ratio:.4g}", verdict=verdict,
                flags=cells[10], run=run, label=labels.get(rid, ""))
    order = [r["id"] for r in json.load(open(os.path.join(HERE, "rows.json")))["rows"]]
    with open(CSV_PATH, "w", newline="") as f:
        w = csv.DictWriter(f, FIELDS)
        w.writeheader()
        for rid in order:
            if rid in data:
                w.writerow({k: (f"{v:g}" if isinstance(v, float) else v) for k, v in data[rid].items()})
    counts = {}
    for d in data.values():
        counts[d["verdict"]] = counts.get(d["verdict"], 0) + 1
    print(f"{len(data)} rows -> {CSV_PATH}: {counts}")


THEMES = {
    "light": dict(surface="#ffffff", ink="#191919", ink2="#666666", grid="#e7e7e7",
                  axis="#c2c2c2", facil="#257de0", node="#f47230", link="#b4b4b4",
                  passc="#257de0", failc="#dc3c3d", excc="#a8a8a8"),
    "dark": dict(surface="#0d1117", ink="#efefef", ink2="#9c9c9c", grid="#262b33",
                 axis="#474747", facil="#338ced", node="#e76624", link="#5a5f66",
                 passc="#338ced", failc="#eb6263", excc="#6e7176"),
}
FONT = 'font-family="system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"'


def fmt_ratio(r):
    if 0.995 <= r < 1:
        return f"{r:.3f}×"
    return f"{r:.2f}×" if r >= 0.1 else f"{r:.2g}×"


def svg_open(w, h, t, title, desc):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'role="img" aria-labelledby="t d" {FONT}>',
            f'<title id="t">{escape(title)}</title><desc id="d">{escape(desc)}</desc>',
            f'<rect width="{w}" height="{h}" rx="8" fill="{t["surface"]}"/>']


def throughput_svg(rows, t, date):
    W, top, rowh = 830, 92, 26
    lx, x0, x1 = 16, 300, 730
    lo, hi = 2e3, 1.5e6
    H = top + rowh * len(rows) + 46
    X = lambda v: x0 + (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * (x1 - x0)
    out = svg_open(W, H, t, "Facil.jl vs Node.js throughput",
                   "Dumbbell chart: requests or messages per second for Facil.jl and the fastest Node.js "
                   "option, per scoreboard row, log scale, with the Facil/Node ratio.")
    out.append(f'<text x="{lx}" y="30" font-size="17" font-weight="600" fill="{t["ink"]}">'
               'Throughput, Facil.jl vs the fastest Node.js option per row</text>')
    out.append(f'<text x="{lx}" y="51" font-size="12.5" fill="{t["ink2"]}">Requests (or WebSocket '
               f'messages) per second, log scale, median of 3 runs. Apple M5 Pro, macOS, {date}.</text>')
    ly = 76
    out.append(f'<circle cx="{lx + 6}" cy="{ly - 4}" r="5" fill="{t["facil"]}"/>'
               f'<text x="{lx + 16}" y="{ly}" font-size="12.5" fill="{t["ink"]}">Facil.jl</text>'
               f'<circle cx="{lx + 84}" cy="{ly - 4}" r="5" fill="none" stroke="{t["node"]}" stroke-width="2.5"/>'
               f'<text x="{lx + 94}" y="{ly}" font-size="12.5" fill="{t["ink"]}">Node.js</text>'
               f'<text x="{lx + 160}" y="{ly}" font-size="12.5" fill="{t["ink2"]}">'
               '‡ approved exception (Facil behind, accepted)</text>')
    out.append(f'<text x="{W - 16}" y="{ly}" font-size="12" text-anchor="end" fill="{t["ink2"]}">'
               'Facil ÷ Node</text>')
    gy0, gy1 = top - 6, top + rowh * len(rows)
    for v, lab in ((3e3, "3k"), (1e4, "10k"), (3e4, "30k"), (1e5, "100k"), (3e5, "300k"), (1e6, "1M")):
        x = X(v)
        out.append(f'<line x1="{x:.1f}" y1="{gy0}" x2="{x:.1f}" y2="{gy1}" stroke="{t["grid"]}" stroke-width="1"/>')
        out.append(f'<text x="{x:.1f}" y="{gy1 + 18}" font-size="11.5" text-anchor="middle" '
                   f'fill="{t["ink2"]}" style="font-variant-numeric: tabular-nums">{lab}</text>')
    out.append(f'<line x1="{x0}" y1="{gy1}" x2="{x1}" y2="{gy1}" stroke="{t["axis"]}" stroke-width="1"/>')
    for i, r in enumerate(rows):
        y = top + rowh * i + rowh / 2
        f, n, ratio = float(r["facil"]), float(r["node"]), float(r["ratio"])
        mark = " ‡" if r["verdict"] == "EXCEPTION" else ""
        tip = (f'{r["row"]} {r["name"]}: Facil {float(r["facil"]):,.0f}, {r["opponent"]} '
               f'{float(r["node"]):,.0f} ({fmt_ratio(ratio)}, {r["verdict"]})')
        out.append(f'<g><title>{escape(tip)}</title>')
        out.append(f'<rect x="0" y="{y - rowh / 2:.1f}" width="{W}" height="{rowh}" fill="transparent"/>')
        out.append(f'<text x="{x0 - 14}" y="{y + 4.5:.1f}" font-size="13" text-anchor="end" '
                   f'fill="{t["ink"]}">{escape(r["label"])}</text>')
        out.append(f'<line x1="{X(f):.1f}" y1="{y:.1f}" x2="{X(n):.1f}" y2="{y:.1f}" '
                   f'stroke="{t["link"]}" stroke-width="2" stroke-linecap="round"/>')
        out.append(f'<circle cx="{X(f):.1f}" cy="{y:.1f}" r="5" fill="{t["facil"]}" '
                   f'stroke="{t["surface"]}" stroke-width="2"/>')
        out.append(f'<circle cx="{X(n):.1f}" cy="{y:.1f}" r="5.5" fill="none" '
                   f'stroke="{t["node"]}" stroke-width="2.5"/>')
        weight = ' font-weight="600"' if ratio < 1 else ""
        out.append(f'<text x="{W - 16}" y="{y + 4.5:.1f}" font-size="13" text-anchor="end"{weight} '
                   f'fill="{t["ink"]}" style="font-variant-numeric: tabular-nums">{fmt_ratio(ratio)}{mark}</text>')
        out.append('</g>')
    out.append(f'<text x="{x1}" y="{H - 10}" font-size="11.5" text-anchor="end" fill="{t["ink2"]}">'
               'WebSocket rows (uWS) are against uWebSockets.js; all others against node:http / https / cluster.</text>')
    out.append('</svg>')
    return "\n".join(out)


def ratio_svg(rows, t, date):
    W, H = 830, 470
    x0, x1, y0, y1 = 64, 814, 104, 410
    lo, hi = 0.005, 8
    Y = lambda v: y1 - (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * (y1 - y0)
    rows = sorted(rows, key=lambda r: -float(r["ratio"]))
    n = len(rows)
    counts = {k: sum(r["verdict"] == k for r in rows) for k in ("PASS", "FAIL", "EXCEPTION")}
    out = svg_open(W, H, t, "Facil.jl / Node.js ratio for every scoreboard row",
                   f"Column chart of the Facil/Node ratio for all {n} scoreboard rows, sorted, log scale, "
                   f"with a reference line at 1.0. {counts['PASS']} pass, {counts['FAIL']} fail, "
                   f"{counts['EXCEPTION']} are approved exceptions.")
    out.append(f'<text x="16" y="30" font-size="17" font-weight="600" fill="{t["ink"]}">'
               f'Every scoreboard row: Facil ÷ Node ({n} rows, sorted)</text>')
    out.append(f'<text x="16" y="51" font-size="12.5" fill="{t["ink2"]}">Above 1.0× Facil is faster '
               f'(or uses less), below it Node is. Log scale. Apple M5 Pro, macOS, {date}.</text>')
    lx = 16
    for key, label, col in (("PASS", "Pass", t["passc"]), ("FAIL", "Fail", t["failc"]),
                            ("EXCEPTION", "Approved exception", t["excc"])):
        text = f"{label} {counts[key]}"
        out.append(f'<rect x="{lx}" y="67" width="11" height="11" rx="2" fill="{col}"/>'
                   f'<text x="{lx + 17}" y="77" font-size="12.5" fill="{t["ink"]}">{text}</text>')
        lx += 17 + 7.2 * len(text) + 22
    for v, lab in ((0.01, "0.01×"), (0.1, "0.1×"), (0.5, "0.5×"), (2, "2×"), (5, "5×")):
        y = Y(v)
        out.append(f'<line x1="{x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}" stroke="{t["grid"]}" stroke-width="1"/>')
        out.append(f'<text x="{x0 - 8}" y="{y + 4:.1f}" font-size="11.5" text-anchor="end" '
                   f'fill="{t["ink2"]}">{lab}</text>')
    slot = (x1 - x0) / n
    bw = max(slot - 2, 1.5)
    base = Y(1.0)
    col = {"PASS": t["passc"], "FAIL": t["failc"], "EXCEPTION": t["excc"]}
    for i, r in enumerate(rows):
        v = float(r["ratio"])
        x = x0 + i * slot + (slot - bw) / 2
        yv = Y(max(min(v, hi), lo))
        h = max(abs(base - yv), 4)
        top_ = base - h if v >= 1 else base
        tip = f'{r["row"]} {r["name"]}: {fmt_ratio(v)} ({r["verdict"]})'
        out.append(f'<g><title>{escape(tip)}</title><rect x="{x:.2f}" y="{top_:.2f}" width="{bw:.2f}" '
                   f'height="{h:.2f}" rx="1.5" fill="{col[r["verdict"]]}"/></g>')
    out.append(f'<line x1="{x0}" y1="{base:.1f}" x2="{x1}" y2="{base:.1f}" stroke="{t["ink"]}" stroke-width="1.5"/>')
    out.append(f'<text x="{x0 - 8}" y="{base + 4:.1f}" font-size="11.5" font-weight="600" text-anchor="end" '
               f'fill="{t["ink"]}">1.0×</text>')

    def note(i, text, above, anchor="start", dx=6):
        v = float(rows[i]["ratio"])
        x = x0 + i * slot + slot / 2
        y = Y(max(min(v, hi), lo)) + (-8 if above else 16)
        out.append(f'<text x="{x + (dx if anchor == "start" else -dx):.1f}" y="{y:.1f}" font-size="12" '
                   f'text-anchor="{anchor}" fill="{t["ink2"]}">{escape(text)}</text>')

    by_id = {r["row"]: i for i, r in enumerate(rows)}
    note(by_id["A25a"], "A25a float-sum handler " + fmt_ratio(float(rows[by_id["A25a"]]["ratio"])), True)
    note(by_id["13"], "13 first request (compile) " + fmt_ratio(float(rows[by_id["13"]]["ratio"])),
         False, "end")
    note(by_id["12"], "12 start-up " + fmt_ratio(float(rows[by_id["12"]]["ratio"])), False, "end")
    first_below = next(i for i, r in enumerate(rows) if float(r["ratio"]) < 1)
    xb = x0 + first_below * slot
    out.append(f'<text x="{xb - 6:.1f}" y="{base - 10:.1f}" font-size="12" text-anchor="end" '
               f'fill="{t["ink2"]}">{first_below} rows at or above 1.0×</text>')
    fails = [i for i, r in enumerate(rows) if r["verdict"] == "FAIL"]
    worst = min(float(rows[i]["ratio"]) for i in fails)
    near = sum(float(rows[i]["ratio"]) >= 0.95 for i in fails)
    fx = x0 + (fails[0] + fails[-1] + 1) / 2 * slot
    out.append(f'<line x1="{fx:.1f}" y1="{base + 8:.1f}" x2="{fx:.1f}" y2="{base + 44:.1f}" '
               f'stroke="{t["ink2"]}" stroke-width="1"/>')
    out.append(f'<text x="{fx - 4:.1f}" y="{base + 58:.1f}" font-size="12" text-anchor="end" fill="{t["ink2"]}">'
               f'{len(fails)} fails: {near} within 5% of Node, the worst {fmt_ratio(worst)}</text>')
    out.append(f'<text x="16" y="{H - 30}" font-size="11.5" fill="{t["ink2"]}">Lower-is-better rows '
               '(latency, memory, start-up, CPU) are drawn as Node ÷ Facil, so above the line always favours Facil.</text>')
    out.append(f'<text x="16" y="{H - 13}" font-size="11.5" fill="{t["ink2"]}">Approved exceptions: '
               'Julia start-up, memory and first-request compile, JSON building, GC tails, task hand-offs, '
               'macOS WebSocket limits.</text>')
    out.append('</svg>')
    return "\n".join(out)


def render():
    rows = list(csv.DictReader(open(CSV_PATH)))
    by_id = {r["row"]: r for r in rows}
    head = [by_id[rid] for rid, _ in HEADLINE]
    date = DATE
    os.makedirs(ASSETS, exist_ok=True)
    for mode, t in THEMES.items():
        for name, svg in (("throughput", throughput_svg(head, t, date)), ("ratio", ratio_svg(rows, t, date))):
            path = os.path.join(ASSETS, f"bench-{name}-{mode}.svg")
            with open(path, "w") as f:
                f.write(svg + "\n")
            print(path)


if __name__ == "__main__":
    build_data() if sys.argv[1:] == ["data"] else render()
