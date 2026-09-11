#!/usr/bin/env python3
"""Regenerate the SPI flash chip name table from the UEFITool repository.

Fetches common/descriptor.cpp from github.com/LongSoft/UEFITool (branch
new_engine) and rewrites one file in the DumpCompare tree:

  Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift

That file is what turns a JEDEC id out of a flash descriptor's VSCC table into
the name of a chip — "EF4019" into "Winbond W25Q256" — which is what the
descriptor's detail panel lists. The table is UEFITool's `jedecIdToUString`,
a `switch` of `case 0xEF4019: return UString("Winbond W25Q256");` lines grouped
by vendor, and this turns it into one Swift dictionary literal.

Run it from anywhere; the repository root is resolved relative to this file
(the skill lives at <repo>/Skills/update-jedec-ids/scripts/), or pass --repo to
point it elsewhere. --source reads a local descriptor.cpp instead of fetching.

Stdlib only, and the run is a diff to review rather than a blind rewrite: it
prints how many chips it read and which vendors they came from, and writes the
file only when something changed.
"""

import argparse
import os
import re
import sys
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/"
    "common/descriptor.cpp"
)
OUTPUT = "Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift"

CASE = re.compile(r'case\s+0x([0-9A-Fa-f]{6})\s*:\s*return\s+UString\("([^"]+)"\)')
VENDOR_COMMENT = re.compile(r"^\s*//\s*(.+?)\s*$")


def fetch(url):
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8")


def parse(source):
    """The switch's cases in file order, with the vendor comment above each run.

    Returns [(jedec_id, chip_name, vendor_heading)].
    """
    entries = []
    vendor = ""
    inside = False
    for line in source.splitlines():
        if "jedecIdToUString" in line:
            inside = True
            continue
        if not inside:
            continue
        if line.strip() == "}":
            break
        match = CASE.search(line)
        if match:
            entries.append((int(match.group(1), 16), match.group(2), vendor))
            continue
        comment = VENDOR_COMMENT.match(line)
        if comment and "//" in line and "case" not in line:
            vendor = comment.group(1)
    return entries


def swift(entries):
    lines = [
        "import Foundation",
        "",
        "// GENERATED from `common/descriptor.cpp` of github.com/LongSoft/UEFITool,",
        "// branch `new_engine` — the `jedecIdToUString` table.",
        "//",
        "// Regenerate with the `update-jedec-ids` skill, which re-fetches that file",
        "// and rewrites this one. Do not edit by hand: the next regeneration",
        "// overwrites it.",
        "//",
        "// What this holds: the name of the SPI flash chip a JEDEC id stands for.",
        "// A flash descriptor's VSCC table lists the chips the board's firmware was",
        "// built to drive, by id alone, and an id is not something a bench can read.",
        "// The descriptor's detail panel shows the name beside it.",
        "enum JedecIDs {",
        "    /// The chip a 24-bit JEDEC id names — vendor byte, then the two device",
        "    /// bytes — or nil for one this table does not know.",
        "    static func name(of id: UInt32) -> String? { table[id] }",
        "",
        "    /// How many chips the table knows, for the test that the generated",
        "    /// file is the whole of upstream's rather than a truncated read of it.",
        "    static var count: Int { table.count }",
        "",
        "    private static let table: [UInt32: String] = [",
    ]
    vendor = None
    for id_value, name, heading in entries:
        if heading != vendor:
            vendor = heading
            lines.append("        // " + vendor)
        lines.append('        0x%06X: "%s",' % (id_value, name))
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, "..", "..", ".."))

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=default_repo, help="the DumpCompare tree")
    parser.add_argument("--source", help="a local descriptor.cpp instead of fetching")
    args = parser.parse_args()

    source = (
        open(args.source, encoding="utf-8").read() if args.source else fetch(SOURCE_URL)
    )
    entries = parse(source)
    if len(entries) < 100:
        print("read only %d chips — the switch was not found as expected" % len(entries),
              file=sys.stderr)
        return 1

    vendors = []
    for _, _, heading in entries:
        if heading not in vendors:
            vendors.append(heading)
    print("%d chips from %d vendors: %s" % (len(entries), len(vendors), ", ".join(vendors)))

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
