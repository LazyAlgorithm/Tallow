import re, sys
"""Gives every field without an initializer in a [HandleData] struct `= default` (struct this() must assign them)."""
p, name = sys.argv[1], sys.argv[2]
s = open(p).read()
a = s.index(f'struct {name}\n{{'); b = s.index('public this() { }', a)
block = s[a:b]
block = re.sub(r'^(\t(?:\[[^\]]*\]\s*)*public (?!this)[\w<>.,\[\] ]+ \w+);$', r'\1 = default;', block, flags=re.M)
s = s[:a] + block + s[b:]
open(p, 'w').write(s)
