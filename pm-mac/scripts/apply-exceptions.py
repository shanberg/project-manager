#!/usr/bin/env python3
"""Re-applies never-filter.txt to the lists already committed in Resources/BlockLists.

`build-blocklists.sh` does this as part of a full regeneration, but a full regeneration needs the
network and a SafariConverterLib checkout and produces a 2.2 MB diff per list. Editing the exception
set should not need any of that: this unpacks what is committed, replaces the shipped tail, and
packs it again. Running it twice is the same as running it once.

    scripts/apply-exceptions.py [--check]

`--check` verifies without writing, which is what you want in CI: it fails if the committed lists
are not what never-filter.txt says they should be.
"""
import glob
import importlib.util
import os
import re
import sys

# Loaded by path because the module's filename has a hyphen in it, which `import` cannot spell and
# which is not worth renaming a file build-blocklists.sh already calls by name.
_spec = importlib.util.spec_from_file_location(
    "pack_blocklist", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pack-blocklist.py"))
_pack = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pack)
deflate, exception_rule, finish = _pack.deflate, _pack.exception_rule, _pack.finish
inflate, is_canary_rule, never_filter_hosts = _pack.inflate, _pack.is_canary_rule, _pack.never_filter_hosts

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTS = os.path.join(HERE, "Resources", "BlockLists")


def blocked(rules: list, url: str) -> bool:
    """Whether this list, on its own, refuses `url`.

    The engine in miniature: walk in order, remember whether a block is standing, and let an
    `ignore-previous-rules` clear it. Domain-scoped triggers are skipped rather than guessed at —
    `if-domain` is matched against the document, which a URL on its own does not have, and the
    exceptions this verifies are deliberately not written that way.
    """
    standing = False
    for rule in rules:
        trigger = rule.get("trigger", {})
        if "if-domain" in trigger or "unless-domain" in trigger:
            continue
        try:
            if not re.search(trigger.get("url-filter", ""), url):
                continue
        except re.error:
            continue
        action = rule.get("action", {}).get("type")
        if action == "block":
            standing = True
        elif action == "ignore-previous-rules":
            standing = False
    return standing


def probes(host: str) -> list:
    return [f"https://{host}/",
            f"https://{host}/appleauth/jslog",
            f"https://sub.{host}/anything?q=1"]


def main() -> int:
    check = "--check" in sys.argv
    hosts = never_filter_hosts()
    if not hosts:
        sys.exit("never-filter.txt lists no hosts — refusing to strip every exception silently.")

    files = sorted(glob.glob(os.path.join(LISTS, "*.json.deflate")))
    if not files:
        sys.exit(f"no lists in {LISTS}")

    stale = []
    for path in files:
        name = os.path.basename(path).split(".")[0]
        before = inflate(path)
        after = finish(list(before), name)
        if before != after:
            stale.append(name)
            if not check:
                deflate(after, name, LISTS)

        # The verification is the point of the exercise, so it runs either way — over what is now on
        # disk in a write run, and over what *would* be written in a check run.
        for host in hosts:
            for url in probes(host):
                if blocked(after, url):
                    sys.exit(f"{name}: still blocks {url} despite an exception for {host}")
        # The tail has to be exactly one canary followed by exactly the exceptions, because that
        # shape is what makes the next run able to find it again. See `finish`.
        # The canary goes before the exceptions, so prove no exception can reach it: an
        # `ignore-previous-rules` matching the canary's own URL would switch a list off while it
        # went on reporting itself in force.
        for host in hosts:
            if re.search(exception_rule(host)["trigger"]["url-filter"], "https://pm-canary.invalid/"):
                sys.exit(f"{host}: its exception matches the canary's URL and would cancel it")
        canaries = [i for i, r in enumerate(after) if is_canary_rule(r)]
        tail = after[canaries[0] + 1:] if canaries else None
        if len(canaries) != 1 or tail != [exception_rule(h) for h in hosts]:
            sys.exit(f"{name}: tail is not one canary followed by {len(hosts)} exception(s)")
        print(f"    {name:<14} {len(after):>7} rules "
              f"({canaries[0]} converted, 1 canary, {len(hosts)} exception(s))")

    if check and stale:
        sys.exit("out of date with never-filter.txt: " + ", ".join(stale)
                 + "\nrun scripts/apply-exceptions.py and commit the result")
    print("==> " + (f"rewrote {len(stale)} list(s)" if stale else "already up to date"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
