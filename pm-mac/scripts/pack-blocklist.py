#!/usr/bin/env python3
"""Packs one converted list for shipping inside the app bundle.

Kept beside build-blocklists.sh rather than inline in it, because a heredoc inside a heredoc is how
you get a shell script that silently stops being the script you wrote.
"""
import json
import sys
import zlib

CEILING = 150_000


def pack(path: str, name: str, out: str) -> int:
    rules = json.load(open(path))
    if len(rules) >= CEILING:
        sys.exit(f"{name}: converter emitted {len(rules)} rules — it capped at {CEILING} and "
                 f"truncated the list. Split the source before shipping it.")
    # The canary. Keyed to a host that cannot resolve, so it can never fire on a real page.
    rules.append({"trigger": {"url-filter": ".*", "if-domain": ["*pm-canary.invalid"]},
                  "action": {"type": "css-display-none", "selector": f"#pm-canary-{name}"}})
    blob = json.dumps(rules, separators=(",", ":")).encode()
    # Raw DEFLATE, which is what Foundation's `.zlib` decompresses. 18 MB of JSON becomes 2.2 MB,
    # and on a launch that finds the compiled list already in the store it is never unpacked at all.
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    open(f"{out}/{name}.json.deflate", "wb").write(packer.compress(blob) + packer.flush())
    return len(rules)


if __name__ == "__main__":
    print(pack(sys.argv[1], sys.argv[2], sys.argv[3]))
