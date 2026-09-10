#!/usr/bin/env python3
"""Packs one converted list for shipping inside the app bundle.

Kept beside build-blocklists.sh rather than inline in it, because a heredoc inside a heredoc is how
you get a shell script that silently stops being the script you wrote.
"""
import json
import os
import re
import sys
import zlib

CEILING = 150_000

NEVER_FILTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "never-filter.txt")


def never_filter_hosts(path: str = NEVER_FILTER) -> list:
    """The hosts nothing may block. See never-filter.txt for what earns a place."""
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line.lower())
    return out


def exception_rule(host: str) -> dict:
    """One `ignore-previous-rules` rule covering a host and everything under it.

    Matched on the request URL, in the shape the converter itself emits, rather than with
    `if-domain` — that field is matched against the *document*, and the requests this exists for are
    made from an identity provider's iframe inside a page on some other domain entirely.
    """
    return {"trigger": {"url-filter": r"^[^:]+://+([^:/]+\.)?%s[/:]" % re.escape(host)},
            "action": {"type": "ignore-previous-rules"}}


def is_canary_rule(rule: dict) -> bool:
    trigger = rule.get("trigger", {})
    return (rule.get("action", {}).get("type") == "css-display-none"
            and trigger.get("if-domain") == ["*pm-canary.invalid"])


def canary_rule(name: str) -> dict:
    """Keyed to a host that cannot resolve, so it can never fire on a real page."""
    return {"trigger": {"url-filter": ".*", "if-domain": ["*pm-canary.invalid"]},
            "action": {"type": "css-display-none", "selector": f"#pm-canary-{name}"}}


def finish(rules: list, name: str) -> list:
    """The shipped tail of every list: the canary, then the exceptions, in that order.

    **The canary is the boundary marker, which is why it goes first.** Applying this twice has to be
    the same as applying it once, so the tail has to be findable again — and it cannot be found by
    shape. A converted `@@||host^` exception is an `ignore-previous-rules` with a host-anchored
    `url-filter` and nothing else, which is character-for-character what this appends: the shipped
    lists carry six of them already, one of them for a bank. Recognising "ours" that way would
    quietly delete real allowlist entries every time this ran. The canary is keyed to a reserved
    `.invalid` host that no filter list can reference, so it is the one rule in here that is
    unambiguously PM's, and everything after it is PM's too.

    Putting the exceptions after it costs nothing. `ignore-previous-rules` only cancels actions for
    a URL it matches, every exception is anchored to a real host, and the canary only ever fires on
    `pm-canary.invalid` — a host no exception can match, now or when the list grows.
    """
    rules = list(rules)
    for i, rule in enumerate(rules):
        if is_canary_rule(rule):
            rules = rules[:i]                    # back to what the converter emitted
            break
    rules.append(canary_rule(name))
    rules += [exception_rule(host) for host in never_filter_hosts()]
    return rules


def deflate(rules: list, name: str, out: str) -> None:
    blob = json.dumps(rules, separators=(",", ":")).encode()
    # Raw DEFLATE, which is what Foundation's `.zlib` decompresses. 18 MB of JSON becomes 2.2 MB,
    # and on a launch that finds the compiled list already in the store it is never unpacked at all.
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    open(f"{out}/{name}.json.deflate", "wb").write(packer.compress(blob) + packer.flush())


def inflate(path: str) -> list:
    return json.loads(zlib.decompressobj(-15).decompress(open(path, "rb").read()))


def pack(path: str, name: str, out: str) -> int:
    rules = json.load(open(path))
    if len(rules) >= CEILING:
        sys.exit(f"{name}: converter emitted {len(rules)} rules — it capped at {CEILING} and "
                 f"truncated the list. Split the source before shipping it.")
    rules = finish(rules, name)
    deflate(rules, name, out)
    return len(rules)


if __name__ == "__main__":
    print(pack(sys.argv[1], sys.argv[2], sys.argv[3]))
