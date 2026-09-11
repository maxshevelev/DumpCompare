#!/usr/bin/env python3
"""Regenerate the UEFI Type/Subtype tables from the UEFITool repository.

Fetches common/types.h and common/types.cpp from github.com/LongSoft/UEFITool
(branch new_engine) and rewrites one file in the ByteRipper tree:

  Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift

The GUID catalogue (common/guids.csv) is not generated: the app downloads it
fresh at run time and ships no baseline, so there is nothing to keep in the
tree.

Run it from anywhere; the repository root is resolved relative to this file
(the skill lives at <repo>/Skills/update-uefi-types/scripts/), or
pass --repo to override. Pass --no-fetch to parse files already on disk in
--workdir instead of downloading.

This is the body of the `update-uefi-types` skill. It is deliberately
deterministic: the same repository files always give the same Swift, so a
regeneration is a diff, never a rewrite-by-hand.
"""

import argparse
import os
import re
import shutil
import sys
import tempfile
import urllib.request

REPO = "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/common/"

TYPES_SWIFT = "Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift"


def fetch(url, dest_dir, name):
    """Download `url` into `dest_dir/<name>` and return the text.

    Always downloads: this is an update, and a cached copy is a stale answer.
    """
    print(f"  fetching {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "ByteRipper"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
    path = os.path.join(dest_dir, name)
    with open(path, "wb") as handle:
        handle.write(data)
    return data.decode("utf-8")


def enum_body(text, enum_name):
    """The text between `enum <name> {` and its matching `};`."""
    match = re.search(r"enum\s+" + re.escape(enum_name) + r"\s*\{", text)
    if not match:
        return None
    start = match.end()
    depth = 1
    index = start
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1
    return text[start:index - 1]


def strip_comments(body):
    """Drop `//` comment lines and trailing comments.

    A comment line is dropped whole, not stripped in place: `RegionSubtypes`
    carries a `// Intel` line before its first entry, and a comma split would
    glue that line to the entry it precedes, hiding `DescriptorRegion = 0`.
    """
    lines = []
    for line in body.splitlines():
        comment = line.find("//")
        if comment >= 0:
            line = line[:comment]
        lines.append(line)
    return "\n".join(lines)


def parse_enum(body):
    """`A = 5, B, C` -> {A:5, B:6, C:7}."""
    values = {}
    if body is None:
        return values
    next_value = None
    for raw in strip_comments(body).split(","):
        entry = raw.strip()
        if not entry:
            continue
        if "=" in entry:
            name, value = entry.split("=", 1)
            name = name.strip()
            value = int(value.strip())
            next_value = value
        else:
            name = entry
            next_value = 0 if next_value is None else next_value + 1
            value = next_value
        if name:
            values[name] = value
    return values


def parse_item_types(types_h):
    return parse_enum(enum_body(types_h, "ItemTypes"))


def namespace_body(text, namespace_name):
    """The text between `namespace <name> {` and its matching `}`."""
    match = re.search(r"namespace\s+" + re.escape(namespace_name) + r"\s*\{", text)
    if not match:
        return None
    start = match.end()
    depth = 1
    index = start
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1
    return text[start:index - 1]


def parse_subtypes(types_h):
    """Every enum inside `namespace Subtypes`, name -> {member: value}.

    Scoped to the namespace: `types.h` also carries `ActionTypes` and
    `ItemTypes`, and neither belongs in the `Sub` table.
    """
    body = namespace_body(types_h, "Subtypes") or ""
    subtypes = {}
    for match in re.finditer(r"enum\s+(\w+)\s*\{", body):
        name = match.group(1)
        subtypes[name] = parse_enum(enum_body(body, name))
    return subtypes


def function_body(text, function_name):
    """The text between `<name>(` and the matching close of its body."""
    match = re.search(re.escape(function_name) + r"\s*\([^)]*\)\s*\{", text)
    if not match:
        return None
    start = match.end()
    depth = 1
    index = start
    while index < len(text) and depth > 0:
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1
    return text[start:index - 1]


def parse_type_names(types_cpp):
    """itemTypeToUString: {code: name} via `case Types::X: return UString("Y")`."""
    body = function_body(types_cpp, "itemTypeToUString") or ""
    names = {}
    for case, name in re.findall(
        r"case\s+Types::(\w+)\s*:\s*return\s+UString\(\"([^\"]*)\"\)", body
    ):
        names[case] = name
    return names


def parse_region_names(types_cpp):
    """regionTypeToUString: {code: name} via `case Subtypes::X: return UString("Y")`."""
    body = function_body(types_cpp, "regionTypeToUString") or ""
    names = {}
    for case, name in re.findall(
        r"case\s+Subtypes::(\w+)\s*:\s*return\s+UString\(\"([^\"]*)\"\)", body
    ):
        names[case] = name
    return names


def parse_subtype_names(types_cpp, item_types):
    """itemSubtypeToUString: {type_code: {subtype_code: name}}.

    Only the cases that answer directly with a name are kept; the File/Section/
    Region delegations are skipped (Region is folded in from regionTypeToUString
    by the caller, File/Section are named by the FFS/section tables at runtime).
    """
    body = function_body(types_cpp, "itemSubtypeToUString") or ""
    result = {}
    # Split the body into `case Types::X:` blocks.
    blocks = re.split(r"case\s+Types::(\w+)\s*:", body)
    # blocks = [prefix, X1, body1, X2, body2, ...]
    for i in range(1, len(blocks) - 1, 2):
        type_name = blocks[i]
        block = blocks[i + 1]
        if type_name not in item_types:
            continue
        type_code = item_types[type_name]
        pairs = re.findall(
            r"subtype\s*==\s*Subtypes::(\w+)\s*\)\s*return\s+UString\(\"([^\"]*)\"\)",
            block,
        )
        if not pairs:
            continue
        table = {}
        for sub_name, name in pairs:
            table[sub_name] = name
        result[type_code] = table
    return result


def hex_literal(value):
    """A byte constant as a Swift hex literal: 60 -> 0x3C, 0 -> 0x00.

    Every code in these tables is a byte, and hex is how a firmware bench reads
    one — the same way the C++ writes its `0x3Ch`-style answers — so the
    generated Swift spells them in hex rather than decimal.
    """
    return f"0x{value:02X}"


def swift_int_dict(pairs, indent="        "):
    """[(int, str)] -> a Swift `[Int: String]` literal body, keys in hex."""
    if not pairs:
        return "[:]"
    lines = []
    for key, value in sorted(pairs):
        escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
        lines.append(f"{indent}{hex_literal(key)}: \"{escaped}\",")
    return "[\n" + "\n".join(lines) + "\n    ]"


def swift_nested_dict(tables, indent="        "):
    """{type_code: {sub_name: name}} -> a Swift `[Int: [Int: String]]` literal, keys in hex."""
    if not tables:
        return "[:]"
    lines = []
    for type_code in sorted(tables):
        inner = tables[type_code]
        inner_lines = ", ".join(
            f"{hex_literal(code)}: \"{name.replace('\"', '\\\"')}\""
            for code, name in sorted(inner.items())
        )
        lines.append(f"{indent}{hex_literal(type_code)}: [{inner_lines}],")
    return "[\n" + "\n".join(lines) + "\n    ]"


def swift_case_name(c_identifier):
    """`AptioSignedCapsule` -> `aptioSignedCapsule`; `PSPDirectory` -> `pspDirectory`.

    Lowercases the leading run of capitals, keeping the one that starts the next
    word, so an acronym reads as a word rather than `pSPDirectory`.
    """
    if not c_identifier:
        return c_identifier
    i = 0
    length = len(c_identifier)
    while i < length and c_identifier[i].isupper():
        i += 1
    if i == 0:
        return c_identifier  # already starts lowercase
    if i == length:
        return c_identifier.lower()  # all capitals
    if i == 1:
        return c_identifier[0].lower() + c_identifier[1:]
    # The last capital of the run is the start of the next word: keep it.
    return c_identifier[: i - 1].lower() + c_identifier[i - 1 :]


def render_types_swift(item_types, subtypes, type_names, region_names, subtype_tables):
    type_codes = {name: code for name, code in item_types.items()}
    type_names_by_code = {code: type_names.get(name, "Unknown") for name, code in item_types.items()}

    # Region names are keyed by region member name; fold them in by code.
    region_codes = subtypes.get("RegionSubtypes", {})
    region_names_by_code = {code: region_names.get(name, "") for name, code in region_codes.items()}

    # The subtype tables, keyed by type code, with member names resolved to codes.
    resolved = {}
    for type_code, member_names in subtype_tables.items():
        # Find the Subtypes enum that owns these members.
        table = {}
        for enum_name, members in subtypes.items():
            for member, code in members.items():
                if member in member_names:
                    table[code] = member_names[member]
        if table:
            resolved[type_code] = table
    # Region is answered by regionTypeToUString, not itemSubtypeToUString.
    if "Region" in type_codes:
        resolved[type_codes["Region"]] = region_names_by_code

    lines = []
    lines.append("import Foundation")
    lines.append("")
    lines.append("// GENERATED from `common/types.h` and `common/types.cpp` of")
    lines.append("// github.com/LongSoft/UEFITool, branch `new_engine`.")
    lines.append("//")
    lines.append("// Regenerate with the `update-uefi-types` skill, which re-fetches those two")
    lines.append("// files and rewrites this one. Do not edit the tables by hand: the next")
    lines.append("// regeneration overwrites them, and a hand edit is a fork from the")
    lines.append("// classification the rest of the tool reads from.")
    lines.append("//")
    lines.append("// What this holds, and why it is a file of its own: the Type and Subtype the")
    lines.append("// structure tree shows for a node are UEFITool's, not ours — `Types::ItemTypes`")
    lines.append("// and the `*ToUString` lookups — so the tree reads the way UEFITool's does.")
    lines.append("// The tables are baked into the build rather than fetched at run time: they")
    lines.append("// are small, they are the classification the whole panel leans on, and a")
    lines.append("// firmware bench should not need the network to say what a BIOS region is.")
    lines.append("")
    lines.append("/// UEFITool's classification of an image element, mirroring")
    lines.append("/// `Types::ItemTypes` and the `itemTypeToUString` / `itemSubtypeToUString` /")
    lines.append("/// `regionTypeToUString` lookups in `common/types.cpp`.")
    lines.append("public enum UEFITypes {")
    lines.append("    // MARK: - `Types::ItemTypes` (types.h)")
    lines.append("")
    lines.append("    /// The item-type codes, `Root = 0x3C` and counting.")
    lines.append("    public enum Item: UInt8 {")
    for name, code in sorted(item_types.items(), key=lambda kv: kv[1]):
        lines.append(f"        case {swift_case_name(name)} = {hex_literal(code)}")
    lines.append("    }")
    lines.append("")
    lines.append("    // MARK: - `Subtypes::*` (types.h)")
    lines.append("")
    # A flat namespace: two enums sharing a member name would collide. The C++
    # keeps them apart by enum, so a collision means the repo changed shape and
    # the flat transcription no longer holds — fail rather than emit broken Swift.
    seen = {}
    for enum_name, members in subtypes.items():
        for member in members:
            swift_name = swift_case_name(member)
            if swift_name in seen:
                print(
                    f"error: subtype member `{member}` appears in both "
                    f"`{seen[swift_name]}` and `{enum_name}`; the flat `Sub` "
                    "namespace cannot hold both",
                    file=sys.stderr,
                )
                sys.exit(1)
            seen[swift_name] = enum_name

    lines.append("    /// The subtype codes, grouped by the item type that gives them a meaning.")
    lines.append("    public enum Sub {")
    for enum_name in sorted(subtypes):
        members = subtypes[enum_name]
        if not members:
            continue
        lines.append(f"        /// `{enum_name}`.")
        for member, code in sorted(members.items(), key=lambda kv: kv[1]):
            lines.append(f"        public static let {swift_case_name(member)}: UInt8 = {hex_literal(code)}")
    lines.append("    }")
    lines.append("")
    lines.append("    // MARK: - Lookups")
    lines.append("")
    lines.append("    /// The word for an item-type code. An unknown code keeps its number.")
    lines.append("    public static func typeName(_ type: UInt8) -> String {")
    lines.append("        typeNames[Int(type)] ?? String(format: \"Unknown %02Xh\", type)")
    lines.append("    }")
    lines.append("")
    lines.append("    /// The word for a flash-descriptor region type. Unknown keeps its number.")
    lines.append("    public static func regionName(_ type: UInt8) -> String {")
    lines.append("        regionNames[Int(type)] ?? String(format: \"Unknown %02Xh\", type)")
    lines.append("    }")
    lines.append("")
    lines.append("    /// The word for a subtype, given the item type that owns it. Nil where")
    lines.append("    /// the type has no named subtypes — `File` and `Section` delegate to the")
    lines.append("    /// FFS and section type tables, which a caller names itself.")
    lines.append("    public static func subtypeName(type: UInt8, _ subtype: UInt8) -> String? {")
    lines.append("        subtypeNames[Int(type)]?[Int(subtype)]")
    lines.append("    }")
    lines.append("")
    lines.append("    // MARK: - The tables")
    lines.append("")
    lines.append("    /// `itemTypeToUString`, transcribed.")
    lines.append("    private static let typeNames: [Int: String] =")
    lines.append("        " + swift_int_dict(sorted(type_names_by_code.items())).strip())
    lines.append("")
    lines.append("    /// `regionTypeToUString`, transcribed: the flash-descriptor region type.")
    lines.append("    private static let regionNames: [Int: String] =")
    lines.append("        " + swift_int_dict(sorted(region_names_by_code.items())).strip())
    lines.append("")
    lines.append("    /// `itemSubtypeToUString`, transcribed and keyed by item type. Region is")
    lines.append("    /// folded in from `regionTypeToUString`; File and Section are absent on")
    lines.append("    /// purpose, named by the FFS and section type tables at run time.")
    lines.append("    private static let subtypeNames: [Int: [Int: String]] =")
    lines.append("        " + swift_nested_dict(resolved).strip())
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=None, help="repository root (default: auto)")
    parser.add_argument("--workdir", default=None, help="where to fetch/parse from")
    parser.add_argument("--no-fetch", action="store_true", help="parse on-disk files, do not download")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    # scripts/ -> skill dir -> Skills -> repo root
    repo = args.repo or os.path.abspath(os.path.join(script_dir, "..", "..", ".."))
    workdir = args.workdir or repo

    print(f"repo:    {repo}")
    print(f"workdir: {workdir}")

    def read(name):
        path = os.path.join(workdir, name)
        if not os.path.exists(path):
            print(f"error: {path} not found (use --no-fetch only with files on disk)", file=sys.stderr)
            sys.exit(1)
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    if args.no_fetch:
        types_h = read("types.h")
        types_cpp = read("types.cpp")
    else:
        # A fresh download into a scratch dir, so the C++ sources never land in
        # the tree and a stale copy is never served. An explicit --workdir is
        # honoured as the download destination and left in place.
        scratch = args.workdir or tempfile.mkdtemp(prefix="uefi-types-")
        made_scratch = args.workdir is None
        try:
            types_h = fetch(REPO + "types.h", scratch, "types.h")
            types_cpp = fetch(REPO + "types.cpp", scratch, "types.cpp")
        finally:
            if made_scratch:
                shutil.rmtree(scratch, ignore_errors=True)

    item_types = parse_item_types(types_h)
    subtypes = parse_subtypes(types_h)
    type_names = parse_type_names(types_cpp)
    region_names = parse_region_names(types_cpp)
    subtype_tables = parse_subtype_names(types_cpp, item_types)

    print(f"item types:   {len(item_types)}")
    print(f"subtype enums: {len(subtypes)}")
    print(f"type names:   {len(type_names)}")
    print(f"region names: {len(region_names)}")
    print(f"subtype tables: {len(subtype_tables)}")

    if not item_types or not type_names or not subtype_tables:
        print("error: parsed nothing; the repository files changed shape?", file=sys.stderr)
        sys.exit(1)

    types_swift = render_types_swift(item_types, subtypes, type_names, region_names, subtype_tables)

    path = os.path.join(repo, TYPES_SWIFT)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(types_swift)
    print(f"wrote {TYPES_SWIFT} ({len(types_swift)} bytes)")


if __name__ == "__main__":
    main()
