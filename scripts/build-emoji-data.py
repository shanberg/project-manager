#!/usr/bin/env python3
"""Build pm-mac/Resources/Emoji/emoji.json — the emoji picker's data — from Unicode's emoji-test.txt.

    scripts/build-emoji-data.py                 # downloads the latest emoji-test.txt from unicode.org
    scripts/build-emoji-data.py emoji-test.txt  # or uses a copy you already have

Groups and order are Unicode's, which is what the system's own picker follows, with two changes that
match it: Smileys & Emotion and People & Body are one group, and Component (bare skin tones and hair
swatches) is dropped. Only fully-qualified emoji are kept, and no skin-tone variants — a project icon
is a mark, and five of every hand would bury the grid.

Each emoji is written as [character, name, emoji version]. EmojiCatalog uses the version to leave out
emoji newer than the Mac it's running on can draw.
"""
import json
import os
import re
import sys
import urllib.request

SOURCE = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
OUT = os.path.join(os.path.dirname(__file__), "..", "pm-mac", "Resources", "Emoji", "emoji.json")
MERGED = {"Smileys & Emotion": "Smileys & People", "People & Body": "Smileys & People"}
SKIN_TONES = set(range(0x1F3FB, 0x1F400))
LINE = re.compile(r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*\S+\s+E(\d+\.\d+)\s+(.+)$")


def read_source(argv):
    if len(argv) > 1:
        with open(argv[1], encoding="utf-8") as f:
            return f.read()
    with urllib.request.urlopen(SOURCE) as response:
        return response.read().decode("utf-8")


def build(text):
    version = re.search(r"^# Version: (\S+)", text, re.M)
    groups, current = [], None
    for line in text.splitlines():
        if line.startswith("# group:"):
            name = MERGED.get(line.split(":", 1)[1].strip(), line.split(":", 1)[1].strip())
            if name == "Component":
                current = None
                continue
            current = next((g for g in groups if g["name"] == name), None)
            if current is None:
                current = {"name": name, "emoji": []}
                groups.append(current)
            continue
        match = LINE.match(line)
        if not match or current is None:
            continue
        points = [int(p, 16) for p in match.group(1).split()]
        if any(p in SKIN_TONES for p in points):
            continue
        current["emoji"].append(["".join(chr(p) for p in points), match.group(3), match.group(2)])
    return {"unicodeVersion": version.group(1) if version else None, "groups": groups}


def main(argv):
    data = build(read_source(argv))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    total = sum(len(g["emoji"]) for g in data["groups"])
    print(f"wrote {os.path.normpath(OUT)}: Emoji {data['unicodeVersion']}, {total} emoji in {len(data['groups'])} groups")


if __name__ == "__main__":
    main(sys.argv)
