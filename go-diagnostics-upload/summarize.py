#!/usr/bin/env python3
"""Summarise a `go test -json` stream (as written by `gotestsum --jsonfile`) as Markdown.

Usage: summarize.py <test.json> [top_n]

Reports the slowest packages and tests, plus per-package GC pressure when the test binaries ran
with GODEBUG=gctrace=1 (see README: `-exec "env GODEBUG=gctrace=1"` sets it for test binaries only,
unlike an environment variable, which would also flood the compiler's output).
Never raises on malformed lines: partial files from a killed job are expected.
"""
import json
import re
import sys
from collections import defaultdict

GC_LINE = re.compile(r"gc \d+ @[\d.]+s .*?(\d+)->(\d+)->(\d+) MB, (\d+) MB goal")


def summarize(path, top_n=10):
    pkg_elapsed = {}
    test_elapsed = {}
    pkg_failed = set()
    gc_count = defaultdict(int)
    gc_peak_heap = defaultdict(int)
    gc_peak_goal = defaultdict(int)
    events = 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            events += 1
            pkg, test, action = ev.get("Package"), ev.get("Test"), ev.get("Action")
            if not pkg:
                continue
            if action in ("pass", "fail", "skip") and "Elapsed" in ev:
                if test:
                    test_elapsed[(pkg, test)] = ev["Elapsed"]
                else:
                    pkg_elapsed[pkg] = ev["Elapsed"]
            if action == "fail" and not test:
                pkg_failed.add(pkg)
            if action == "output":
                for m in GC_LINE.finditer(ev.get("Output", "")):
                    gc_count[pkg] += 1
                    gc_peak_heap[pkg] = max(gc_peak_heap[pkg], int(m.group(1)))
                    gc_peak_goal[pkg] = max(gc_peak_goal[pkg], int(m.group(4)))

    out = [f"### Go test diagnostics ({events} events, {len(pkg_elapsed)} packages)", ""]
    if pkg_elapsed:
        out += ["Slowest packages:", "", "| package | seconds | result |", "|---|--:|---|"]
        for pkg, secs in sorted(pkg_elapsed.items(), key=lambda kv: -kv[1])[:top_n]:
            out.append(f"| {pkg} | {secs:.1f} | {'FAIL' if pkg in pkg_failed else 'ok'} |")
        out.append("")
    if test_elapsed:
        out += ["Slowest tests:", "", "| test | seconds |", "|---|--:|"]
        for (pkg, test), secs in sorted(test_elapsed.items(), key=lambda kv: -kv[1])[:top_n]:
            out.append(f"| {pkg}.{test} | {secs:.1f} |")
        out.append("")
    if gc_count:
        out += [
            "GC pressure per package (from gctrace; peak heap = largest heap size at the start of a GC):",
            "",
            "| package | GCs | peak heap MB | peak goal MB |",
            "|---|--:|--:|--:|",
        ]
        for pkg, n in sorted(gc_peak_heap.items(), key=lambda kv: -kv[1])[:top_n]:
            out.append(f"| {pkg} | {gc_count[pkg]} | {gc_peak_heap[pkg]} | {gc_peak_goal[pkg]} |")
        out.append("")
    elif events:
        out += ["No gctrace lines found (run test binaries with `-exec \"env GODEBUG=gctrace=1\"` to get per-package heap).", ""]
    return "\n".join(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: summarize.py <test.json> [top_n]")
    print(summarize(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 10))
