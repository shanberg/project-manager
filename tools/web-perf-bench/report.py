#!/usr/bin/env python3
"""Summarise one or more result folders side by side.

  report.py results/chrome-cold-… results/folio-cold-… [--json out.json]

Each folder has events.jsonl (layout-start / layout-settled / tile / layout-end / crossing) and
procs.jsonl (sampler ticks). Rows are per layout, pooled over rounds; round 0 is reported apart
because it is the first time the HTTP cache sees the files.
"""
import json, statistics, sys
from collections import defaultdict
from pathlib import Path


def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 1) if xs else None


def p95(xs):
    xs = sorted(x for x in xs if x is not None)
    return round(xs[min(len(xs) - 1, round(0.95 * (len(xs) - 1)))], 1) if xs else None


def cpu_between(ticks, t0, t1):
    """CPU seconds used per role between t0 and t1 (epoch s), and peak resident MB per role."""
    before = [t for t in ticks if t['t'] < t0]
    alive_at_start = {p[0]: p[2] for p in before[-1]['p']} if before else {}
    first, last, peak = {}, {}, defaultdict(float)
    for tick in ticks:
        if tick['t'] < t0 or tick['t'] > t1:
            continue
        by_role = defaultdict(float)
        for pid, role, cpu, rss in tick['p']:
            first.setdefault(pid, cpu)
            last[pid] = (role, cpu)
            by_role[role] += rss
        for role, rss in by_role.items():
            peak[role] = max(peak[role], rss)
    used = defaultdict(float)
    for pid, (role, cpu) in last.items():
        # A process alive before the window counts from where it was; one born inside it, from zero.
        used[role] += max(0.0, cpu - alive_at_start.get(pid, 0.0))
    return {k: round(v, 2) for k, v in used.items()}, dict(peak)


def summarise(folder):
    folder = Path(folder)
    events = load(folder / 'events.jsonl')
    ticks = load(folder / 'procs.jsonl') if (folder / 'procs.jsonl').exists() else []
    rows = defaultdict(lambda: defaultdict(list))
    starts = {}
    for e in events:
        key = (e.get('layout'), e.get('round'))
        if e['kind'] == 'layout-start':
            starts[key] = e['t']
        elif e['kind'] == 'layout-end':
            r = rows[(e['layout'], 'first' if e['round'] == 0 else 'later')]
            r['readyMs'].append(e.get('readyMs'))
            t0, t1 = starts[key] / 1000, e['t'] / 1000
            used, peak = cpu_between(ticks, t0, t1)
            for role, s in used.items():
                r[f'cpu.{role}'].append(s)
            for role, mb in peak.items():
                r[f'mb.{role}'].append(mb)
        elif e['kind'] == 'crossing':
            r = rows[(e['layout'], 'first' if e['round'] == 0 else 'later')]
            for k in ('dropped', 'dropped2s', 'worstMs', 'over50'):
                if k in e:
                    r[f'host.{k}'].append(e[k])
        elif e['kind'] == 'tile':
            r = rows[(e['layout'], 'first' if e['round'] == 0 else 'later')]
            rep = e.get('report') or {}
            marks = rep.get('marks') or {}
            # Page-clock marks → ms since the tile was asked to open.
            offset = (rep.get('origin') or e['opened']) - e['opened']
            for m in ('fcp', 'selector', 'settled'):
                if marks.get(m) is not None:
                    r[f'{e["site"]}.{m}'].append(marks[m] + offset)
            for ph in rep.get('phases', []):
                if ph.get('frames', 0) >= 3:
                    kind = e['site'].rstrip('AB')
                    r[f'{kind}.{ph["phase"]}.p95ms'].append(ph['p95'])
                    r[f'{kind}.{ph["phase"]}.fps'].append(ph['fps'])
                    r[f'{kind}.{ph["phase"]}.over50'].append(ph['over50'])
            r['loafBlockingMs'].append(rep.get('loafBlockingMs'))
            r[f'{e["site"]}.wheels'].append(rep.get('wheels'))
            for k, v in (e.get('native') or {}).items():
                r[f'{e["site"]}.native.{k}'].append(v)
    return {f'{layout} ({which})': {k: {'median': med(v), 'p95': p95(v), 'n': len(v)} for k, v in sorted(cols.items())}
            for (layout, which), cols in sorted(rows.items())}


def main():
    args = sys.argv[1:]
    skip = {i + 1 for i, a in enumerate(args) if a == '--json'}
    folders = [a for i, a in enumerate(args) if not a.startswith('--') and i not in skip]
    out = {Path(f).name: summarise(f) for f in folders}
    if '--json' in sys.argv:
        json.dump(out, open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)
    layouts = sorted({l for s in out.values() for l in s})
    for layout in layouts:
        print(f'\n### {layout}\n')
        metrics = sorted({m for s in out.values() for m in s.get(layout, {})})
        print('| metric | ' + ' | '.join(out) + ' |')
        print('|---|' + '---|' * len(out))
        for m in metrics:
            cells = []
            for s in out.values():
                v = s.get(layout, {}).get(m)
                cells.append('' if not v else f"{v['median']} (p95 {v['p95']}, n={v['n']})")
            print(f'| {m} | ' + ' | '.join(cells) + ' |')


if __name__ == '__main__':
    main()
