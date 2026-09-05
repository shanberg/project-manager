#!/usr/bin/env python3
"""Turns the converter's 'advanced rules' into the compact map PM injects into pages.

Content blockers cannot express two things filter lists rely on: scriptlets, which run a snippet of
JavaScript before a page's own scripts, and extended CSS, whose selectors match on things CSS cannot
ask about. SafariConverterLib emits those separately, for an app to interpret. This turns them into
a lookup table keyed by domain.

AdGuard publish reference implementations of both, and both are GPL-3.0 and together about 3 MB —
too much law and too much JavaScript to inject into every page. They are not needed: across the four
lists PM ships, three scriptlets account for 93% of all scriptlet uses and one pseudo-class for 91%
of extended CSS. Those are implemented in advanced.js, which PM owns. Anything else is counted and
dropped, and the count is printed here so it stays honest.

Emitted shape, keyed by domain, "*" for rules that apply everywhere:

    ["c",   name, value]         document.cookie
    ["l",   key,  value]         localStorage      ("$remove$" removes)
    ["s",   key,  value]         sessionStorage    ("$remove$" removes)
    ["css", text]                a stylesheet to inject
    ["ht",  selector, text]      :has-text(...) — hide matches whose text contains `text`
"""
import collections
import json
import re
import sys
import zlib

# ("ubo-set-cookie", "name", "value", ...maybe more)
SCRIPTLET = re.compile(r'#%#//scriptlet\((.*)\)\s*$')
ARG = re.compile(r'"((?:[^"\\]|\\.)*)"')
HAS_TEXT = re.compile(r'^(.*?):has-text\(\s*(.*?)\s*\)\s*$')

KEEP = {"ubo-set-cookie": "c", "ubo-set-cookie-reload": "c",
        "ubo-set-local-storage-item": "l", "ubo-set-session-storage-item": "s"}


def domains_of(head: str):
    """Domains a rule applies to, dropping negations — a rule that is 'everywhere except x' is
    treated as everywhere, which is what the filter list means and what a lookup table can hold."""
    out = []
    for part in head.split(","):
        part = part.strip()
        if not part or part.startswith("~"):
            continue
        out.append(part.lower())
    return out or ["*"]


def build(path: str):
    table = collections.defaultdict(list)
    kept = collections.Counter()
    dropped = collections.Counter()

    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("!"):
            continue

        if "#%#//scriptlet" in line:
            head, _, _ = line.partition("#%#")
            if "#@%#" in line:                      # an exception rule; nothing to apply
                dropped["scriptlet exception"] += 1
                continue
            match = SCRIPTLET.search(line)
            if not match:
                dropped["unparsed scriptlet"] += 1
                continue
            args = [a.replace('\\"', '"') for a in ARG.findall(match.group(1))]
            if not args:
                dropped["unparsed scriptlet"] += 1
                continue
            kind = KEEP.get(args[0])
            if kind is None or len(args) < 3:
                dropped[args[0]] += 1
                continue
            for domain in domains_of(head):
                table[domain].append([kind, args[1], args[2]])
            kept[args[0]] += 1
            continue

        for marker, handler in (("#$#", "css"), ("#?#", "ext"), ("#$?#", "ext")):
            if marker not in line:
                continue
            head, _, body = line.partition(marker)
            if handler == "css":
                for domain in domains_of(head):
                    table[domain].append(["css", body])
                kept["css"] += 1
            else:
                found = HAS_TEXT.match(body)
                if found and ":has-text" not in found.group(1):
                    selector, text = found.group(1), found.group(2)
                    for domain in domains_of(head):
                        table[domain].append(["ht", selector, text])
                    kept[":has-text"] += 1
                elif not re.search(r":(-abp-|matches-css|xpath|upward|nth-ancestor|contains|matches-attr|matches-property|remove\b)", body):
                    # Plain CSS, or :has()/:not(), which WebKit supports natively.
                    for domain in domains_of(head):
                        table[domain].append(["css", body + " { display: none !important; }"])
                    kept["native selector"] += 1
                else:
                    dropped["extended css"] += 1
            break
        else:
            dropped["other"] += 1

    return table, kept, dropped


if __name__ == "__main__":
    source, out = sys.argv[1], sys.argv[2]
    table, kept, dropped = build(source)
    # The canary, matching the one in each rule list: a rule on a host that cannot resolve, so
    # CanvasContentBlocker can ask at launch whether this half is being applied either.
    table["pm-canary.invalid"] = [["css", "#pm-canary-advanced { display: none !important; }"]]
    blob = json.dumps(table, separators=(",", ":"), sort_keys=True).encode()
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    open(f"{out}/advanced.json.deflate", "wb").write(packer.compress(blob) + packer.flush())
    total_kept = sum(kept.values())
    total_dropped = sum(dropped.values())
    print(f"    advanced       {total_kept:7d} rules over {len(table)} domains "
          f"({len(blob)/1e6:.2f} MB json)")
    for name, count in kept.most_common():
        print(f"        kept    {name:32s} {count}")
    print(f"        dropped {total_dropped} unsupported "
          f"({total_kept * 100 // max(total_kept + total_dropped, 1)}% coverage)")
    for name, count in dropped.most_common(6):
        print(f"                {name:32s} {count}")
