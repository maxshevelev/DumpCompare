#!/usr/bin/env python3
"""Regenerate the palette's Swift definitions from its colour sets.

Reads every `*.colorset` in

  Packages/AppPalette/Sources/AppPalette/Resources/Colors.xcassets

and rewrites one file:

  Packages/AppPalette/Sources/AppPalette/Palette+Generated.swift

The colour sets are the palette: a colour is picked in Xcode's own editor, with
both appearances side by side, and nothing about it is typed into Swift. The
generated file exists because `swift build` copies an `.xcassets` verbatim
rather than compiling it — only Xcode runs `actool` — so every package test in
this repository would otherwise see no colours at all. It is the same numbers,
readable without a compiled catalogue, and the app suite's `SemanticPaletteTests`
holds the two to each other.

Run it from anywhere; the repository root is resolved relative to this file
(the skill lives at <repo>/Skills/update-palette/scripts/), or pass --repo.

Stdlib only, and the run is a diff to review: it prints every colour it read,
and writes the file only when something changed.
"""

import argparse
import json
import os
import sys

CATALOGUE = "Packages/AppPalette/Sources/AppPalette/Resources/Colors.xcassets"
OUTPUT = "Packages/AppPalette/Sources/AppPalette/Palette+Generated.swift"


def component(value):
    """One sRGB component as a float, from the two spellings a colour set uses."""
    text = str(value).strip()
    if text.startswith("0x"):
        return int(text, 16) / 255.0
    number = float(text)
    # A colour set written in 0-255 rather than 0-1: whole numbers above one.
    return number / 255.0 if number > 1 else number


def read_set(path):
    """(light, dark) as (r, g, b) triples, or None for a set we cannot read."""
    with open(os.path.join(path, "Contents.json"), encoding="utf-8") as file:
        contents = json.load(file)

    shades = {}
    for entry in contents.get("colors", []):
        colour = entry.get("color")
        if not colour:
            continue
        components = colour.get("components", {})
        try:
            rgb = tuple(component(components[key]) for key in ("red", "green", "blue"))
        except (KeyError, ValueError):
            return None
        appearances = entry.get("appearances", [])
        dark = any(a.get("value") == "dark" for a in appearances)
        shades["dark" if dark else "light"] = rgb

    if "light" not in shades:
        return None
    # A set with no dark variant is the same colour in both themes, which the
    # catalogue expresses by leaving the second entry out.
    return shades["light"], shades.get("dark", shades["light"])


def swift(entries):
    lines = [
        "// GENERATED from `Colors.xcassets` beside this file.",
        "//",
        "// Regenerate with the `update-palette` skill, which re-reads the colour sets",
        "// and rewrites this one. Do not edit by hand: a colour is picked in Xcode's",
        "// colour editor, and the next regeneration overwrites whatever is typed here.",
        "//",
        "// Why it exists at all: `swift build` copies an `.xcassets` verbatim instead",
        "// of compiling it — only Xcode runs `actool` — so a package test would see no",
        "// colours. These are the same numbers, readable without a compiled catalogue.",
        "public extension SemanticColors.Definition {",
    ]
    for name, (light, dark) in entries:
        member = name[0].lower() + name[1:]
        member = member[len("semantic"):] if member.startswith("semantic") else member
        member = member[0].lower() + member[1:]
        lines += [
            "    static let %s = SemanticColors.Definition(" % member,
            '        name: "%s",' % name,
            "        light: (%.3f, %.3f, %.3f)," % light,
            "        dark: (%.3f, %.3f, %.3f))" % dark,
            "",
        ]
    members = [
        (n[len("Semantic"):] if n.startswith("Semantic") else n) for n, _ in entries
    ]
    members = [m[0].lower() + m[1:] for m in members]
    lines += [
        "    /// Every colour set in the catalogue, in the order it names them.",
        "    static let all = [" + ", ".join(members) + "]",
        "}",
        "",
    ]
    return "\n".join(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, "..", "..", ".."))

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=default_repo, help="the DumpCompare tree")
    args = parser.parse_args()

    catalogue = os.path.join(args.repo, CATALOGUE)
    if not os.path.isdir(catalogue):
        print("no catalogue at %s" % catalogue, file=sys.stderr)
        return 1

    entries = []
    for name in sorted(os.listdir(catalogue)):
        if not name.endswith(".colorset"):
            continue
        shades = read_set(os.path.join(catalogue, name))
        stem = name[: -len(".colorset")]
        if shades is None:
            print("skipped %s — not an sRGB colour set with a light variant" % stem,
                  file=sys.stderr)
            continue
        entries.append((stem, shades))
        light, dark = shades
        print("%-18s light %s  dark %s"
              % (stem,
                 " ".join("%.3f" % c for c in light),
                 " ".join("%.3f" % c for c in dark)))

    if not entries:
        print("no colour sets read", file=sys.stderr)
        return 1

    path = os.path.join(args.repo, OUTPUT)
    rendered = swift(entries)
    if os.path.exists(path) and open(path, encoding="utf-8").read() == rendered:
        print("%s is already up to date" % OUTPUT)
        return 0
    with open(path, "w", encoding="utf-8") as out:
        out.write(rendered)
    print("wrote %s" % OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
