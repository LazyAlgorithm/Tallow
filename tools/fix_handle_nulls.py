#!/usr/bin/env python3
"""Rewrite `E != null` / `E == null` on handle types reported by BF0472 into E.IsValid / !E.IsValid.
usage: fixnull.py build.log Type [Type...]"""
import re, sys
log = open(sys.argv[1]).read()
types = sys.argv[2:]
pat = re.compile(r"BF0472: The result of the expression is always '(?:true|false)' since a value of type 'Tallow\.(\w+)' can never be null at line (\d+):(\d+) in (\S+\.bf)")
hits = {}
for m in pat.finditer(log):
    t, line, col, f = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
    if t in types:
        hits.setdefault(f, set()).add((line, col))
expr = re.compile(r"((?:[\w.]|<[\w.]+>|\(\)|\[\w+\])+) (!=|==) null")
for f, spots in hits.items():
    L = open(f).read().split('\n')
    for line, col in sorted(spots):
        t = L[line - 1]
        best = None
        for m in expr.finditer(t):
            d = abs(m.start(2) + 1 - col)
            if best is None or d < best[0]:
                best = (d, m)
        if best is None or best[0] > 3:
            print('MANUAL', f, line, t.strip()); continue
        m = best[1]
        e = m.group(1)
        rep = (e + '.IsValid') if m.group(2) == '!=' else ('!' + e + '.IsValid')
        L[line - 1] = t[:m.start()] + rep + t[m.end():]
    open(f, 'w').write('\n'.join(L))
    print('fixed', f, len(spots))
