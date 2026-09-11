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

A set's name says which family it belongs to, and the family decides what the
colour is *for*:

  Semantic<Meaning>   a state a value can be in: good, caution, bad
  Zone<Which>         a tool-module's zone outline over the dump
  Segment<N>          the tint of the Nth piece of a partition
  Difference<What>    the comparison's own fills — a byte that differs

Each family's colours land in that family's `Sets` namespace, and the family
itself gives them the names callers use — `SemanticColors.Sets.good` is the
colour set, `SemanticColors.good` is the `NSColor` a view draws with.

Run it after picking a colour in Xcode:

    python3 Scripts/gen-palette.py

To change a colour: open the catalogue in Xcode, pick the shade for Any
Appearance and for Dark, run this, and read the diff. Nothing else needs
editing — the package's tests pin each family's rules rather than any
particular shade.

To add one: a colour set named for its family, a run of this, and one line in
the family's facade (`SemanticColors`, `ZoneColors`, `SegmentTints`) giving it a
name. The value is the catalogue's; the meaning is Swift's.

Run it from anywhere; the repository root is resolved relative to this file
(it lives at <repo>/Scripts/), or pass --repo.

Stdlib only, and the run is a diff to review: it prints every colour it read,
and writes the file only when something changed.
"""

import argparse
import json
import os
import re
import sys

CATALOGUE = "Packages/AppPalette/Sources/AppPalette/Resources/Colors.xcassets"
OUTPUT = "Packages/AppPalette/Sources/AppPalette/Palette+Generated.swift"

# Each family's prefix, and the Swift type its colours are hung on.
FAMILIES = [
    ("Semantic", "SemanticColors"),
    ("Zone", "ZoneColors"),
    ("Segment", "SegmentTints"),
    ("Difference", "DifferenceColors"),
]


def component(value):
    """One component as a float, from the spellings a colour set uses."""
    text = str(value).strip()
    if text.startswith("0x"):
        return int(text, 16) / 255.0
    number = float(text)
    # A colour set written in 0-255 rather than 0-1: whole numbers above one.
    return number / 255.0 if number > 1 else number


def to_linear(value):
    """Undo the sRGB transfer function, which Display P3 shares."""
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def to_gamma(value):
    """And put it back."""
    if value <= 0.0031308:
        return 12.92 * value
    return 1.055 * (value ** (1 / 2.4)) - 0.055


# Display P3 to sRGB, both D65, in linear light.
P3_TO_SRGB = (
    (1.2249401, -0.2249404, 0.0000000),
    (-0.0420569, 1.0420571, 0.0000000),
    (-0.0196376, -0.0786361, 1.0982735),
)


def as_srgb(rgb, space):
    """`rgb` in sRGB, whatever colour space the colour set wrote it in.

    Xcode's picker writes Display P3 by default, and the same three numbers
    mean a different colour there — which is a colour that reads right in the
    app (the catalogue is converted for us) and wrong in every package test
    (these numbers are read as sRGB). So the conversion happens here, once.
    """
    if space in ("srgb", "extended-srgb", None):
        return rgb
    if space in ("display-p3", "extended-display-p3"):
        linear = [to_linear(c) for c in rgb]
        out = []
        for row in P3_TO_SRGB:
            value = sum(m * c for m, c in zip(row, linear))
            out.append(to_gamma(min(max(value, 0.0), 1.0)))
        return tuple(out)
    raise ValueError("colour space %s" % space)


def read_set(path):
    """(light, dark) as (r, g, b, a) tuples, or None for a set we cannot read."""
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
            rgb = as_srgb(rgb, colour.get("color-space"))
            # A fill is drawn over the dump's own layers, so its alpha is part
            # of the colour rather than a detail of one use of it.
            alpha = float(components.get("alpha", 1))
        except (KeyError, ValueError) as problem:
            print("  %s" % problem, file=sys.stderr)
            return None
        rgb = tuple(round(c, 4) for c in rgb) + (alpha,)
        dark = any(a.get("value") == "dark" for a in entry.get("appearances", []))
        shades["dark" if dark else "light"] = rgb

    if "light" not in shades:
        return None
    # A set with no dark variant is the same colour in both themes, which the
    # catalogue expresses by leaving the second entry out.
    return shades["light"], shades.get("dark", shades["light"])


def member(name, prefix):
    """The Swift name a set is reached by: its name without the family's."""
    stem = name[len(prefix):] if name.startswith(prefix) else name
    if not stem:
        stem = name
    # A trailing number keeps its prefix, so Segment0 is `segment0` rather than
    # a member that starts with a digit.
    if re.fullmatch(r"\d+", stem):
        stem = prefix + stem
    return stem[0].lower() + stem[1:]


def swift(by_family):
    lines = [
        "// GENERATED from `Colors.xcassets` beside this file.",
        "//",
        "// Regenerate with `Scripts/gen-palette.py`, which re-reads the colour sets",
        "// and rewrites this one. Do not edit by hand: a colour is picked in Xcode's",
        "// colour editor, and the next regeneration overwrites whatever is typed here.",
        "//",
        "// Why it exists at all: `swift build` copies an `.xcassets` verbatim instead",
        "// of compiling it — only Xcode runs `actool` — so a package test would see no",
        "// colours. These are the same numbers, readable without a compiled catalogue.",
    ]
    for prefix, type_name in FAMILIES:
        entries = by_family.get(prefix, [])
        if not entries:
            continue
        lines += ["", "public extension %s.Sets {" % type_name]
        for name, (light, dark) in entries:
            lines += [
                "    static let %s = PaletteColor(" % member(name, prefix),
                '        name: "%s",' % name,
                "        light: (%.3f, %.3f, %.3f, %.3f)," % light,
                "        dark: (%.3f, %.3f, %.3f, %.3f))" % dark,
                "",
            ]
        members = [member(name, prefix) for name, _ in entries]
        lines += [
            "    /// Every %s colour set in the catalogue, in its own order." % prefix.lower(),
            "    static let all = [" + ", ".join(members) + "]",
            "}",
        ]
    lines.append("")
    return "\n".join(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, ".."))

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=default_repo, help="the ByteRipper tree")
    args = parser.parse_args()

    catalogue = os.path.join(args.repo, CATALOGUE)
    if not os.path.isdir(catalogue):
        print("no catalogue at %s" % catalogue, file=sys.stderr)
        return 1

    by_family = {}
    stray = []
    for name in sorted(os.listdir(catalogue)):
        if not name.endswith(".colorset"):
            continue
        stem = name[: -len(".colorset")]
        shades = read_set(os.path.join(catalogue, name))
        if shades is None:
            print("skipped %s — not an sRGB colour set with a light variant" % stem,
                  file=sys.stderr)
            continue
        family = next((p for p, _ in FAMILIES if stem.startswith(p)), None)
        if family is None:
            stray.append(stem)
            continue
        by_family.setdefault(family, []).append((stem, shades))
        light, dark = shades
        print("%-11s %-18s light %s  dark %s"
              % (family, stem,
                 " ".join("%.3f" % c for c in light),
                 " ".join("%.3f" % c for c in dark)))

    if stray:
        print("colour sets in no family, so in no Swift: %s" % ", ".join(stray),
              file=sys.stderr)
        print("name them for a family (%s) and run again"
              % ", ".join(p for p, _ in FAMILIES), file=sys.stderr)
        return 1
    if not by_family:
        print("no colour sets read", file=sys.stderr)
        return 1

    path = os.path.join(args.repo, OUTPUT)
    rendered = swift(by_family)
    if os.path.exists(path) and open(path, encoding="utf-8").read() == rendered:
        print("%s is already up to date" % OUTPUT)
        return 0
    with open(path, "w", encoding="utf-8") as out:
        out.write(rendered)
    print("wrote %s" % OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
