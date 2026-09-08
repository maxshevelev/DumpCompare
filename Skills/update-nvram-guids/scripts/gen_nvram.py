#!/usr/bin/env python3
"""Regenerate the NVRAM GUID classifier from the UEFITool repository.

Fetches common/nvram.h and common/nvram.cpp from github.com/LongSoft/UEFITool
(branch new_engine) and rewrites one file in the DumpCompare tree:

  Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift

That file is the classifier the NVRAM volume parser reads: which of a volume's
file-system GUIDs is an NVRAM store, which GUIDs open a VSS2 or FTW store, and
the word to show for a GUID-identity NVRAM node (an EVSA GUID entry, a FlashMap
entry) while the downloaded guids.csv catalogue has no name for it.

Run it from anywhere; the repository root is resolved relative to this file
(the skill lives at <repo>/Skills/update-nvram-guids/scripts/), or pass --repo
to override. Pass --no-fetch to parse files already on disk in --workdir
instead of downloading.

This is the body of the `update-nvram-guids` skill. It is deliberately
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

NVRAM_GUIDS_SWIFT = "Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift"

# The tokens that read as acronyms in a display word, kept in caps. Everything
# else lowercases. A trailing GUID / SIGNATURE token is dropped, not a word.
ACRONYMS = {
    "NVRAM", "NVAR", "VSS", "VSS2", "FDC", "EDKII", "FTW", "SLIC", "CMDB",
    "EVSA", "PEI", "PHOENIX", "FFS", "OEM", "BB", "VAR", "KEY", "DB",
}


def fetch(url, dest_dir, name):
    """Download `url` into `dest_dir/<name>` and return the text.

    Always downloads: this is an update, and a cached copy is a stale answer.
    """
    print(f"  fetching {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "DumpCompare"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
    path = os.path.join(dest_dir, name)
    with open(path, "wb") as handle:
        handle.write(data)
    return data.decode("utf-8")


def parse_h_guids(nvram_h):
    """`extern const UByteArray NAME; // <GUID>` -> {name: guid_string}.

    A declaration with no `//` GUID comment (ZERO_GUID, the _FLASH_MAP text
    signature) carries no guid_string and is left out — that is exactly what
    keeps the non-GUID entries out of the classifier.
    """
    guids = {}
    for line in nvram_h.splitlines():
        match = re.match(
            r"\s*extern\s+const\s+UByteArray\s+(\w+)\s*;\s*(?://\s*(.*))?$", line
        )
        if not match:
            continue
        name, comment = match.group(1), match.group(2)
        if comment and guid_string_to_bytes(comment.strip()) is not None:
            guids[name] = comment.strip()
    return guids


def parse_cpp_bytes(nvram_cpp):
    """`extern const UByteArray NAME ("\\xNN...", N);` -> {name: [bytes]}.

    The name and the byte literal sit on separate lines in the source, so this
    is a dot-all match across the newline between them.
    """
    guids = {}
    for match in re.finditer(
        r'extern\s+const\s+UByteArray\s+(\w+)\s*(?://[^\n]*)?\s*\('
        r'"((?:\\x[0-9A-Fa-f]{2})+)"(?:\s*,\s*(\d+))?\s*\)',
        nvram_cpp,
    ):
        name, byte_text, count = match.group(1), match.group(2), match.group(3)
        guids[name] = [int(token, 16) for token in re.findall(r"\\x([0-9A-Fa-f]{2})", byte_text)]
        if count is not None and len(guids[name]) != int(count):
            print(
                f"warning: {name} declares {count} bytes but the literal has "
                f"{len(guids[name])}",
                file=sys.stderr,
            )
    return guids


def guid_string_to_bytes(guid_string):
    """`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` -> sixteen image-order bytes.

    Mirrors EFIGUID's textual form: the first three fields are little-endian
    numbers, so only the first eight bytes are reversed, in three pieces.
    """
    fields = guid_string.split("-")
    widths = [8, 4, 4, 4, 12]
    if len(fields) != len(widths) or any(
        len(field) != width for field, width in zip(fields, widths)
    ):
        return None
    nibbles = []
    for field in fields:
        for character in field:
            if character not in "0123456789abcdefABCDEF":
                return None
            nibbles.append(int(character, 16))
    bytes_ = []
    for index in range(0, len(nibbles), 2):
        bytes_.append(nibbles[index] << 4 | nibbles[index + 1])
    reordered = bytes_[0:4][::-1] + bytes_[4:6][::-1] + bytes_[6:8][::-1] + bytes_[8:16]
    return reordered


def swift_case_name(c_identifier):
    """`NVRAM_MAIN_STORE_VOLUME_GUID` -> `nvramMainStoreVolume`.

    Lowercases the leading run of capitals, keeping the one that starts the next
    word, and folds the underscore-separated C++ name into a camelCase Swift
    identifier.
    """
    if not c_identifier:
        return c_identifier
    words = c_identifier.split("_")
    first = words[0]
    # A digit in the first word makes it an acronym with a suffix (VSS2);
    # lower the whole thing rather than splitting on the digit.
    if any(ch.isdigit() for ch in first):
        head = first.lower()
    else:
        i = 0
        length = len(first)
        while i < length and first[i].isupper():
            i += 1
        if i == 0:
            head = first
        elif i == length:
            head = first.lower()
        elif i == 1:
            head = first[0].lower() + first[1:]
        else:
            head = first[: i - 1].lower() + first[i - 1 :]
    tail = "".join(word[:1].upper() + word[1:].lower() for word in words[1:])
    return head + tail


def display_word(c_identifier):
    """`NVRAM_MAIN_STORE_VOLUME_GUID` -> `NVRAM main store volume`.

    A trailing GUID / SIGNATURE token is dropped; the rest is joined with
    spaces, acronyms kept in caps and the rest lowercased.
    """
    tokens = c_identifier.split("_")
    while tokens and tokens[-1] in ("GUID", "SIGNATURE"):
        tokens.pop()
    return " ".join(token if token in ACRONYMS else token.lower() for token in tokens)


def swift_bytes_literal(bytes_):
    """[bytes] -> a Swift `[UInt8]` literal body, image order, hex."""
    return "[" + ", ".join(f"0x{b:02X}" for b in bytes_) + "]"


def render_nvram_guids(guids):
    """{name: (bytes, word)} -> the whole NvramGuids.swift source."""
    lines = []
    lines.append("import Foundation")
    lines.append("")
    lines.append("// GENERATED from `common/nvram.h` and `common/nvram.cpp` of")
    lines.append("// github.com/LongSoft/UEFITool, branch `new_engine`.")
    lines.append("//")
    lines.append("// Regenerate with the `update-nvram-guids` skill, which re-fetches those two")
    lines.append("// files and rewrites this one. Do not edit by hand: the next regeneration")
    lines.append("// overwrites it.")
    lines.append("//")
    lines.append("// What this holds, and why it is a file of its own: the NVRAM volume parser")
    lines.append("// classifies a store by its GUID — which file-system GUID is an NVRAM store,")
    lines.append("// which GUID opens a VSS2 or FTW store — and the structure tree names a")
    lines.append("// GUID-identity NVRAM node from here while the downloaded guids.csv has no")
    lines.append("// name for it. The bytes are the image-order bytes the C++ source spells out,")
    lines.append("// so a GUID that moves upstream follows straight into the parser.")
    lines.append("")
    lines.append("/// The NVRAM GUIDs UEFITool names in `common/nvram.h`, and what they mean.")
    lines.append("public enum NvramGuids {")
    lines.append("")

    # The named constants, sorted by name so the diff is stable.
    for name in sorted(guids):
        bytes_, _word = guids[name]
        lines.append(f"    /// {name}.")
        lines.append(f"    public static let {swift_case_name(name)} = EFIGUID(bytes: {swift_bytes_literal(bytes_)})")
        lines.append("")

    lines.append("    /// The word to show for a GUID-identity NVRAM node, when the")
    lines.append("    /// downloaded guids.csv catalogue has no name for it.")
    lines.append("    public static let names: [EFIGUID: String] =")
    lines.append("        [")
    for name in sorted(guids):
        _bytes, word = guids[name]
        lines.append(f"        {swift_case_name(name)}: \"{word}\",")
    lines.append("        ]")
    lines.append("")
    lines.append("    /// The word for a GUID, or nil when it is not one of these.")
    lines.append("    public static func name(of guid: EFIGUID) -> String? { names[guid] }")
    lines.append("")
    lines.append("    /// The two file-system GUIDs whose volume body is an NVRAM store.")
    lines.append("    public static func isStoreVolume(_ guid: EFIGUID) -> Bool {")
    lines.append(
        f"        guid == {swift_case_name('NVRAM_MAIN_STORE_VOLUME_GUID')}"
        f" || guid == {swift_case_name('NVRAM_ADDITIONAL_STORE_VOLUME_GUID')}"
    )
    lines.append("    }")
    lines.append("")
    lines.append("    /// A VSS2 store, by the store GUID that leads its 24-byte header.")
    lines.append("    public static func isVss2Store(_ guid: EFIGUID) -> Bool {")
    lines.append(
        f"        guid == {swift_case_name('NVRAM_VSS2_STORE_GUID')}"
        f" || guid == {swift_case_name('NVRAM_FDC_STORE_GUID')}"
        f" || guid == {swift_case_name('NVRAM_VSS2_AUTH_VAR_KEY_DATABASE_GUID')}"
    )
    lines.append("    }")
    lines.append("")
    lines.append("    /// An FTW working block, by the signature GUID that leads its header. The")
    lines.append("    /// main store's own GUID doubles as the FTW signature of the block that")
    lines.append("    /// protects it.")
    lines.append("    public static func isFtwStore(_ guid: EFIGUID) -> Bool {")
    lines.append(
        f"        guid == {swift_case_name('NVRAM_MAIN_STORE_VOLUME_GUID')}"
        f"\n            || guid == {swift_case_name('EDKII_WORKING_BLOCK_SIGNATURE_GUID')}"
        f"\n            || guid == {swift_case_name('VSS2_WORKING_BLOCK_SIGNATURE_GUID')}"
    )
    lines.append("    }")
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
        nvram_h = read("nvram.h")
        nvram_cpp = read("nvram.cpp")
    else:
        # A fresh download into a scratch dir, so the C++ sources never land in
        # the tree and a stale copy is never served. An explicit --workdir is
        # honoured as the download destination and left in place.
        scratch = args.workdir or tempfile.mkdtemp(prefix="nvram-guids-")
        made_scratch = args.workdir is None
        try:
            nvram_h = fetch(REPO + "nvram.h", scratch, "nvram.h")
            nvram_cpp = fetch(REPO + "nvram.cpp", scratch, "nvram.cpp")
        finally:
            if made_scratch:
                shutil.rmtree(scratch, ignore_errors=True)

    h_guids = parse_h_guids(nvram_h)
    cpp_bytes = parse_cpp_bytes(nvram_cpp)

    guids = {}
    for name in sorted(set(h_guids) & set(cpp_bytes)):
        bytes_ = cpp_bytes[name]
        if len(bytes_) != 16:
            print(f"warning: {name} is not sixteen bytes; skipped", file=sys.stderr)
            continue
        # Drift detector: the .h comment GUID and the .cpp bytes should agree.
        comment_bytes = guid_string_to_bytes(h_guids[name])
        if comment_bytes is not None and comment_bytes != bytes_:
            print(
                f"warning: {name} comment {h_guids[name]} disagrees with the "
                "cpp bytes; the cpp bytes are the source of truth",
                file=sys.stderr,
            )
        guids[name] = (bytes_, display_word(name))

    print(f"guids:        {len(guids)}")
    if not guids:
        print("error: parsed nothing; the repository files changed shape?", file=sys.stderr)
        sys.exit(1)

    source = render_nvram_guids(guids)
    path = os.path.join(repo, NVRAM_GUIDS_SWIFT)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(source)
    print(f"wrote {NVRAM_GUIDS_SWIFT} ({len(source)} bytes)")


if __name__ == "__main__":
    main()
