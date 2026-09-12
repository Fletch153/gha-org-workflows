#!/usr/bin/env python3
"""Scenario coverage grader.

usage: grade-scenarios.py <chain> <out_dir> <test-output-file>

Reads spec/scenarios.json and the overlay's capabilities, decides which scenarios apply,
and checks each applicable scenario id has a passing test in the captured test output.
Matching is by normalised name (lowercase, non-alphanumerics stripped) substring, so
`cache.on_report.x` matches `test_cache_on_report_x`, `cacheOnReportX`, `0x..::m::cache_on_report_x`.
"""
import json, re, sys, pathlib
chain, out_dir, log = sys.argv[1], sys.argv[2], sys.argv[3]
K = pathlib.Path(__file__).resolve().parent.parent / '.claude/skills/chainlink-data-feeds'
corpus = json.load(open(K / 'spec/scenarios.json'))['scenarios']
ov = (K / f'chains/{chain}.md').read_text()
m = re.search(r'\*\*capabilities:\*\*\s*`\[([^\]]*)\]`', ov)
caps = {c.strip() for c in m.group(1).split(',') if c.strip()} if m else set()
norm = lambda s: re.sub(r'[^a-z0-9]', '', s.lower())
text = open(log, errors='replace').read()
# passing test names per framework
passed = []
for pat in (r'^test (\S+?)(?: - should panic)? \.\.\. ok', r'\[PASS\]\s+(\S+?)\(', r'\[ PASS\s*\]\s+(\S+)'):
    for mm in re.finditer(pat, text, re.M):
        passed.append(norm(mm.group(1)))
failed = set()
for pat in (r'^test (\S+?)(?: - should panic)? \.\.\. FAILED', r'\[FAIL[^\]]*\]\s+(\S+?)\(', r'\[ FAIL\s*\]\s+(\S+)'):
    for mm in re.finditer(pat, text, re.M):
        failed.add(norm(mm.group(1)))
applicable = [s for s in corpus if set(s['requires']) <= caps]
na = [s for s in corpus if not set(s['requires']) <= caps]
ok, fail, missing = [], [], []
from collections import Counter
# scenarios may be named with or without the `cache.`/`proxy.` prefix (each contract's tests
# usually live in their own crate/package); when the prefix is dropped, a suffix shared by
# both contracts must be matched by at least that many distinct passing tests.
suffix = lambda i: norm(i.split('.', 1)[1])
share = Counter(suffix(s['id']) for s in applicable)
for s in applicable:
    key, suf = norm(s['id']), suffix(s['id'])
    full = [p for p in passed if key in p]
    part = [p for p in passed if suf in p]
    if full or len(part) >= share[suf]: ok.append(s['id'])
    elif any(key in f or suf in f for f in failed): fail.append(s['id'])
    else: missing.append(s['id'])
print(f"chain={chain} capabilities={sorted(caps)}")
print(f"scenarios: total={len(corpus)} applicable={len(applicable)} not-applicable={len(na)}")
print(f"applicable covered & passing: {len(ok)}/{len(applicable)}  failing: {len(fail)}  missing: {len(missing)}")
for i in fail: print("  FAIL   ", i)
for i in missing: print("  MISSING", i)
sys.exit(0 if not fail and not missing else 1)
