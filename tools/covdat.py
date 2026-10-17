#!/usr/bin/env python3
"""
covdat.py -- read Verilator coverage data files directly.

WHY THIS EXISTS
  verilator_coverage cannot restrict a report to a source path: its only
  filter is --filter-type, which selects by coverage TYPE (verilator_coverage
  --help, 5.050, read 2026-10-09). Section 5.3's gate is per-directory
  (rtl/core), so per-file counts have to come from the data file itself.

WHAT IT ASSUMES, AND HOW EACH ASSUMPTION IS CHECKED
  The data file format is not documented in --help. This parser assumes only:
    1. lines starting '#' and blank lines carry no data;
    2. every other line is   C '<payload>' <count>
    3. <payload> is a run of \\x01<key>\\x02<value> pairs.
  2 and 3 are checked on EVERY line. A line that fails either aborts the run;
  it is never skipped. A parser that drops records it does not understand
  shrinks the denominator, and a smaller denominator reads as better coverage.

  Which key holds the source file, line, hierarchy or point name is NOT
  assumed. 'summary' prints every key present and one decoded record per
  coverage type, so the mapping is read off the data rather than recalled.
  The other commands name the keys they use and abort if those keys are
  absent from the file.

USAGE
  covdat.py summary <file.dat>
  covdat.py dump    <file.dat> --file <suffix>
  covdat.py signals <file.dat> --file <suffix> [--expect a,b,c]
  covdat.py files   <file.dat> [--under <path-substring>]
  covdat.py diff    <a.dat> <b.dat> [--under <path-substring>] [--type <t>]

UNION ACROSS INSTANCES ('files')
  Verilator keys every point by instance path: merging the decoder harness
  with the core harness gives decoder.sv's points TWICE, once per hierarchy
  (observed on 5.020, 2026-10-09; to be confirmed on 5.050). 'files' unions
  them -- a point counts as hit if ANY instance hit it -- keyed on everything
  except the hierarchy. It first asserts that this key is unique within each
  instance; if two points in one instance shared it, the union would fold
  distinct points together and shrink the denominator.
"""

import argparse
import collections
import re
import sys

LINE_RE = re.compile(r"^C '(.*)' (\d+)$")
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")

# Keys this tool READS, for 'dump' and 'signals'. Their presence is checked
# against the data; see need().
K_FILE, K_LINE, K_HIER, K_POINT = "f", "l", "h", "o"


def parse(path):
    recs, bad = [], []
    # latin-1 maps every byte to one code point, so \x01 and \x02 survive and
    # no byte sequence can raise a decode error.
    with open(path, "r", encoding="latin-1") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                bad.append((n, line))
                continue
            rec = {}
            for part in m.group(1).split("\x01"):
                if not part:
                    continue
                if "\x02" not in part:
                    bad.append((n, line))
                    break
                k, v = part.split("\x02", 1)
                rec[k] = v
            rec["_count"] = int(m.group(2))
            recs.append(rec)
    if bad:
        print(f"FATAL: {len(bad)} line(s) of {path} do not match the assumed "
              f"format. Nothing reported.", file=sys.stderr)
        for n, l in bad[:10]:
            print(f"  line {n}: {l[:160]!r}", file=sys.stderr)
        sys.exit(3)
    if not recs:
        sys.exit(f"FATAL: {path} contains no coverage records.")
    return recs


def rtype(r):
    """Coverage type of a record: the 't' key if present, else the part of
    'page' before the first '/'. Which one the data uses is shown by summary."""
    if "t" in r:
        return r["t"]
    page = r.get("page", "")
    return page.split("/", 1)[0] if page else "?"


def need(recs, *keys):
    present = {k for r in recs for k in r if not k.startswith("_")}
    missing = [k for k in keys if k not in present]
    if missing:
        sys.exit(f"FATAL: no record carries key(s) {missing}. Keys present: "
                 f"{sorted(present)}. The format differs from what this tool "
                 f"assumes; run 'summary' and read a decoded record.")


def visible(v):
    return v.replace("\x01", "<01>").replace("\x02", "<02>")


def cmd_summary(recs, path):
    keys = collections.Counter(k for r in recs for k in r if not k.startswith("_"))
    pts = collections.Counter(rtype(r) for r in recs)
    hit = collections.Counter(rtype(r) for r in recs if r["_count"] > 0)
    print(f"{path}: {len(recs)} records")
    print("  keys, with the number of records carrying each:")
    for k, n in sorted(keys.items()):
        print(f"    {k!r}: {n}")
    print("  by coverage type:")
    for t, n in sorted(pts.items()):
        print(f"    {t!r}: {n} points, {hit[t]} hit")
    print("  one decoded record per type:")
    seen = set()
    for r in recs:
        t = rtype(r)
        if t in seen:
            continue
        seen.add(t)
        print(f"    [{t}] " + "  ".join(f"{k}={visible(v)!r}" for k, v in r.items()
                                         if not k.startswith("_"))
              + f"  count={r['_count']}")


def select(recs, suffix):
    need(recs, K_FILE)
    out = [r for r in recs if r.get(K_FILE, "").endswith(suffix)]
    if not out:
        files = sorted({r.get(K_FILE, "") for r in recs})
        sys.exit(f"FATAL: no record's {K_FILE!r} ends with {suffix!r}. "
                 f"Files present: {files}")
    return out


def lineno(r):
    try:
        return int(r.get(K_LINE, "0"))
    except ValueError:
        return 0


def cmd_dump(recs, suffix):
    sel = select(recs, suffix)
    need(sel, K_LINE)
    print(f"{len(sel)} records for *{suffix}  (line, type, count, hier, point)")
    for r in sorted(sel, key=lambda r: (lineno(r), rtype(r), r.get(K_HIER, ""),
                                        r.get(K_POINT, ""))):
        print(f"  {r.get(K_LINE, '?'):>4}  {rtype(r):<10} {r['_count']:>6}  "
              f"{r.get(K_HIER, '-'):<24} {visible(r.get(K_POINT, '-'))}")


def cmd_signals(recs, suffix, expect):
    sel = [r for r in select(recs, suffix) if "toggle" in rtype(r)]
    if not sel:
        types = sorted({rtype(r) for r in recs})
        sys.exit(f"FATAL: no toggle records for *{suffix}. Types present: {types}")
    need(sel, K_POINT)
    pts, hit = collections.Counter(), collections.Counter()
    for r in sel:
        m = NAME_RE.match(r.get(K_POINT, ""))
        name = m.group(0) if m else "<unnamed>"
        pts[name] += 1
        hit[name] += r["_count"] > 0
    print(f"toggle points for *{suffix}, grouped by leading name of {K_POINT!r}:")
    for name in sorted(pts):
        print(f"  {name:<12} {pts[name]:>6} points  {hit[name]:>6} hit")
    if expect:
        absent = [e for e in expect if e not in pts]
        for e in expect:
            print(f"  expect {e:<12} {'PRESENT' if e in pts else 'ABSENT -- no toggle points at all'}")
        if absent:
            print(f"  {len(absent)} expected signal(s) have NO toggle points: {absent}")


def build_union(recs):
    """Union across instances: point key -> summed count. The key is everything
    except the hierarchy, and is asserted unique within each instance."""
    need(recs, K_FILE, K_LINE, K_HIER, K_POINT)
    seen, union, insts = set(), {}, collections.defaultdict(set)
    for r in recs:
        key = (r[K_FILE], r[K_LINE], r.get("n", ""), r.get("page", ""),
               rtype(r), r[K_POINT])
        ikey = key + (r[K_HIER],)
        if ikey in seen:
            sys.exit(f"FATAL: two records share {key} within instance "
                     f"{r[K_HIER]!r}. The union key is not unique; unioning "
                     f"would merge distinct points. Nothing reported.")
        seen.add(ikey)
        union[key] = union.get(key, 0) + r["_count"]
        insts[r[K_FILE]].add(r[K_HIER])
    return union, insts


def cmd_files(recs, under):
    union, insts = build_union(recs)
    rows = collections.defaultdict(collections.Counter)
    for (f, _l, _n, _page, t, _o), c in union.items():
        if under and under not in f:
            continue
        rows[f][(t, "pts")] += 1
        rows[f][(t, "hit")] += c > 0
    if not rows:
        sys.exit(f"FATAL: no file matches --under {under!r}. Files present: "
                 f"{sorted(insts)}")
    types = sorted({t for c in rows.values() for (t, _k) in c})
    print(f"union across instances{f' under {under!r}' if under else ''}:")
    print(f"  {'file':<40} {'inst':>4}  " + "  ".join(f"{t:>18}" for t in types))
    tot = collections.Counter()
    for f in sorted(rows):
        cells = []
        for t in types:
            pts, hit = rows[f][(t, "pts")], rows[f][(t, "hit")]
            tot[(t, "pts")] += pts
            tot[(t, "hit")] += hit
            cells.append(f"{hit:>7} / {pts:<7}  " if pts else f"{'-':>18}")
        print(f"  {f:<40} {len(insts[f]):>4}  " + "  ".join(cells))
    print(f"  {'TOTAL (hit / points)':<40} {'':>4}  " + "  ".join(
        f"{tot[(t, 'hit')]:>7} / {tot[(t, 'pts')]:<7}  " for t in types))


def cmd_diff(recs_a, recs_b, under, only_type, names=False):
    """Which points each run hit, compared on the union key. 'unpaired' counts
    points present in one file's data but not the other's -- nonzero means the
    two files came from differently instrumented builds, and the other columns
    are not comparable."""
    ua, _ = build_union(recs_a)
    ub, _ = build_union(recs_b)
    rows = collections.defaultdict(collections.Counter)
    unpaired = collections.Counter()
    for k in set(ua) | set(ub):
        f, t = k[0], k[4]
        if under and under not in f:
            continue
        if only_type and t != only_type:
            continue
        ha, hb = ua.get(k, 0) > 0, ub.get(k, 0) > 0
        rows[f]["a_only" if ha and not hb else "b_only" if hb and not ha
                else "both" if ha else "neither"] += 1
        if (k in ua) != (k in ub):
            rows[f]["unpaired"] += 1
            m = NAME_RE.match(k[5])
            unpaired[("only in A" if k in ua else "only in B", f, t,
                      m.group(0) if m else "<unnamed>")] += 1
    if not rows:
        sys.exit(f"FATAL: no points match --under {under!r} --type {only_type!r}")
    cols = ["a_only", "b_only", "both", "neither", "unpaired"]
    print(f"diff A vs B{f' under {under!r}' if under else ''}"
          f"{f' type {only_type!r}' if only_type else ''}:")
    print(f"  {'file':<40} " + " ".join(f"{c:>9}" for c in cols))
    tot = collections.Counter()
    for f in sorted(rows):
        tot.update(rows[f])
        print(f"  {f:<40} " + " ".join(f"{rows[f][c]:>9}" for c in cols))
    if names:
        print("unpaired points by signal (side, file, type, top-level name: count):")
        if not unpaired:
            print("  none")
        for (side, f, t, nm), n in sorted(unpaired.items()):
            print(f"  {side:<9} {f:<40} {t:<8} {nm:<24} {n:>7}")
    print("DIFF " + " ".join(f"{c}={tot[c]}" for c in cols))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["summary", "dump", "signals", "files", "diff"])
    ap.add_argument("datafile")
    ap.add_argument("datafile2", nargs="?", help="'diff' only: the second file")
    ap.add_argument("--file", help="source-file suffix to select")
    ap.add_argument("--expect", help="comma-separated signal names that must appear")
    ap.add_argument("--under", help="'files'/'diff': keep files whose path contains this")
    ap.add_argument("--type", help="'diff' only: keep points of exactly this type")
    ap.add_argument("--names", action="store_true",
                    help="'diff' only: list unpaired points by signal name")
    a = ap.parse_args()
    if a.cmd == "diff":
        if not a.datafile2:
            sys.exit("FATAL: 'diff' needs two data files")
        cmd_diff(parse(a.datafile), parse(a.datafile2), a.under, a.type, a.names)
        return
    recs = parse(a.datafile)
    if a.cmd == "summary":
        cmd_summary(recs, a.datafile)
        return
    if a.cmd == "files":
        cmd_files(recs, a.under)
        return
    if not a.file:
        sys.exit(f"FATAL: '{a.cmd}' needs --file <suffix>")
    if a.cmd == "dump":
        cmd_dump(recs, a.file)
    else:
        cmd_signals(recs, a.file, a.expect.split(",") if a.expect else [])


if __name__ == "__main__":
    main()
