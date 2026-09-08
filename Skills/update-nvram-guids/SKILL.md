---
name: update-nvram-guids
description: Regenerate Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift from the UEFITool repository's common/nvram.h and common/nvram.cpp. Use when the NVRAM GUID classifier the NVRAM volume parser and structure tree read needs refreshing from upstream, when the user asks to "update the NVRAM GUIDs" / "sync the NVRAM GUID table", or after LongSoft/UEFITool changes those two files.
---

# Update NVRAM GUIDs

Regenerate the NVRAM GUID classifier that the NVRAM volume parser reads to
decide which of a volume's bytes is which store, and that the structure tree
uses to name a GUID-identity NVRAM node.

The classifier does not invent its table — it reads UEFITool's. The GUIDs are
the `extern const UByteArray` declarations in `common/nvram.h` (each with a
GUID spelled out in its `//` comment) and the image-order bytes that
`common/nvram.cpp` gives them. Those two files are the source of truth, and this
skill turns them into the one generated Swift file the app compiles against:

```
Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift
```

## Why a generated file, and why a skill

The GUIDs are baked into the build rather than fetched at run time: they are
few and fixed, the parser leans on them on every store candidate, and a firmware
bench should not need the network to say what a store is. The cost of baking
them in is that they go stale when UEFITool changes, so this skill is the
repeatable way to bring them current. It is deterministic — the same repository
files always produce the same Swift — so a run is a diff to review, never a
rewrite by hand.

**Do not hand-edit `NvramGuids.swift`.** Its header says so. A hand edit is a
fork from the classification the parser and the tree read from, and the next run
of this skill overwrites it. If a GUID looks wrong, the fix is in the parser
below, not in the generated file.

## What it does and does not touch

- **Regenerates** `NvramGuids.swift` from `common/nvram.h` + `common/nvram.cpp`.
- **Does not** generate the *words* the parser uses to recognize a store — the
  `$VSS`, `_FDC`, `_FLASH_MAP`, `EVSA`, `CMDB`, `RSA1` and `WINDOWS`
  discriminators live in `enum NVRAM` in `NvramParser.swift`, hand-written next
  to the parser that reads them. The generated file holds only the 16-byte GUIDs
  and the display words derived from their C++ names.
- **Does not** generate the two *volume-level* names ("NVRAM main store",
  "NVRAM additional store") — those already live in `KnownGUIDs` and are not
  duplicated here.

## How to run it

From the repository root, run the bundled script. It fetches the two files
fresh from `github.com/LongSoft/UEFITool` (branch `new_engine`) into a scratch
directory, parses them, and rewrites the one Swift file:

```bash
python3 Skills/update-nvram-guids/scripts/gen_nvram.py
```

The script resolves the repository root from its own location, so it can be run
from anywhere; `--repo <path>` overrides it if the tree lives elsewhere.

A successful run prints the parse count and the file it wrote:

```
guids:        27
wrote Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift (9667 bytes)
```

### Offline / from local files

If the network is unavailable, or you want to parse a specific pair of files
already on disk, pass `--no-fetch --workdir <dir>` where `<dir>` holds
`nvram.h` and `nvram.cpp`:

```bash
python3 Skills/update-nvram-guids/scripts/gen_nvram.py --no-fetch --workdir /path/to/files
```

## After a run

1. **Review the diff.** `git diff Packages/UEFIImage/Sources/UEFIImage/NvramGuids.swift`.
   A routine refresh adds or renames a GUID. A large diff means UEFITool
   restructured its NVRAM GUIDs — read it before trusting it. The byte count is a
   tripwire: the table holds exactly the 27 GUIDs the source names, and
   `NvramGuidsTests` asserts that count.
2. **Build.** The generated file must compile against the parser and the
   classification that reference it:
   ```bash
   cd Packages/UEFIImage && swift build
   cd ../../Modules/UEFITool && swift build
   ```
3. **Run the UEFI tests** to confirm the parser still walks stores the way it
   should:
   ```bash
   cd Modules/UEFITool && swift test
   ```
   and the package's own `NvramGuidsTests`/parser tests:
   ```bash
   cd Packages/UEFIImage && swift test
   ```
4. Commit the regenerated file when the diff is sound. The generated file and
   the skill are the unit of change.

## How the script parses the sources

Keep this in mind when the repository changes shape and a run fails.

- **`common/nvram.h`**: a `extern const UByteArray NAME;` line becomes a GUID
  only when its trailing `//` comment parses as a GUID. A declaration with no
  such comment (`ZERO_GUID`, the `_FLASH_MAP` text signature) is skipped on
  purpose — that is exactly what keeps the non-GUID entries out of the
  classifier.
- **`common/nvram.cpp`**: a `extern const UByteArray NAME ("\xNN...", N);` block
  — name and literal on separate lines — yields the image-order bytes. Only
  names present in *both* files survive; a byte count that is not 16 is skipped
  with a warning.
- **Drift detector**: the `.h` comment GUID and the `.cpp` bytes are
  cross-checked, field by field (the first three GUID fields are little-endian,
  so only the first eight bytes are reversed). A disagreement prints a warning;
  the `.cpp` bytes are the source of truth, mirroring the sibling
  `update-uefi-types` skill's stance.
- **Camel-casing**: `NVRAM_MAIN_STORE_VOLUME_GUID` becomes the Swift identifier
  `nvramMainStoreVolume` and the display word `NVRAM main store volume` (a
  trailing `GUID` / `SIGNATURE` token is dropped; acronyms stay caps). The
  names are emitted sorted, so the diff is stable.

## Failure modes

- **`error: parsed nothing; the repository files changed shape?`** — neither the
  `.h` GUID declarations nor the `.cpp` byte dumps matched the expected form. The
  repository moved. Read the current `nvram.h` / `nvram.cpp`, update the regexes
  in `scripts/gen_nvram.py` to the new shape, and re-run. Do not loosen a regex
  until you have looked at what changed.
- **A build failure after a clean run** — a generated identifier the parser or
  the tests reference changed name or disappeared. Reconcile the references with
  the new table; the parser and the classifier are hand-written and outlive any
  single regeneration.
- **`NvramGuidsTests` count assert fails** — a new GUID joined (count rose) or a
  declaration stopped carrying a `//` GUID comment (count fell). Check whether
  the change is a real upstream addition before relaxing the guard.
