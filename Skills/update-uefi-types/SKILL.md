---
name: update-uefi-types
description: Regenerate Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift from the UEFITool repository's common/types.h and common/types.cpp. Use when the UEFI Type/Subtype classification shown in the UEFI Structure tree needs refreshing from upstream, when the user asks to "update the UEFI types" / "sync the type tables", or after LongSoft/UEFITool changes those two files.
---

# Update UEFI Types

Regenerate the UEFI Type/Subtype classification that the UEFI Structure tree
shows in its **Type** and **Subtype** columns.

The tree does not invent this classification — it reads UEFITool's. The item
types are `Types::ItemTypes` in `common/types.h`; the words for them and their
subtypes are the `itemTypeToUString` / `itemSubtypeToUString` /
`regionTypeToUString` lookups in `common/types.cpp`. Those two files are the
source of truth, and this skill turns them into the one generated Swift file
the app compiles against:

```
Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift
```

## Why a generated file, and why a skill

The tables are baked into the build rather than fetched at run time: they are
small, the whole panel leans on them, and a firmware bench should not need the
network to say what a BIOS region is. The cost of baking them in is that they go
stale when UEFITool changes, so this skill is the repeatable way to bring them
current. It is deterministic — the same repository files always produce the same
Swift — so a run is a diff to review, never a rewrite by hand.

**Do not hand-edit `UEFITypes.swift`.** Its header says so. A hand edit is a
fork from the classification the rest of the tool reads from, and the next run
of this skill overwrites it. If a table looks wrong, the fix is in the parser
below, not in the generated file.

## What it does and does not touch

- **Regenerates** `UEFITypes.swift` from `common/types.h` + `common/types.cpp`.
- **Does not** generate anything for `common/guids.csv`. The GUID *names* the
  tree shows for a node are a different thing: the app downloads a fresh
  `guids.csv` at run time (`LongSoftGuidsRepository` in `UEFIToolUI`) and ships
  no baseline, so there is nothing to keep in the tree. Do not add a guids
  baseline here — that was a deliberate design decision.

## How to run it

From the repository root, run the bundled script. It fetches the two files
fresh from `github.com/LongSoft/UEFITool` (branch `new_engine`) into a scratch
directory, parses them, and rewrites the one Swift file:

```bash
python3 Skills/update-uefi-types/scripts/gen_uefi.py
```

The script resolves the repository root from its own location, so it can be run
from anywhere; `--repo <path>` overrides it if the tree lives elsewhere.

A successful run prints the parse counts and the file it wrote:

```
item types:   46
subtype enums: 19
type names:   46
region names: 19
subtype tables: 17
wrote Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift (12120 bytes)
```

### Offline / from local files

If the network is unavailable, or you want to parse a specific pair of files
already on disk, pass `--no-fetch --workdir <dir>` where `<dir>` holds
`types.h` and `types.cpp`:

```bash
python3 Skills/update-uefi-types/scripts/gen_uefi.py --no-fetch --workdir /path/to/files
```

## After a run

1. **Review the diff.** `git diff Packages/UEFIImage/Sources/UEFIImage/UEFITypes.swift`.
   A routine refresh changes a few names or adds a case. A large diff means
   UEFITool restructured its types — read it before trusting it.
2. **Build.** The generated file must compile against the classification that
   references it:
   ```bash
   cd Packages/UEFIImage && swift build
   cd ../../Modules/UEFITool && swift build
   ```
3. **Run the UEFI tests** to confirm the tree still reads the way it should:
   ```bash
   cd Modules/UEFITool && swift test
   ```
4. Commit the regenerated file when the diff is sound. The generated file and
   the skill are the unit of change.

## How the script parses the sources

Keep this in mind when the repository changes shape and a run fails.

- **`Types::ItemTypes`** (`types.h`): a C enum, `Root = 60` and counting. Each
  member becomes a case of `UEFITypes.Item`.
- **`namespace Subtypes`** (`types.h`): every enum inside it becomes a group of
  `static let` codes in the flat `UEFITypes.Sub` namespace. The script is scoped
  to the `Subtypes` namespace on purpose — `types.h` also carries `ActionTypes`
  and `ItemTypes`, and neither belongs in `Sub`. A full-line `//` comment is
  dropped before the comma split, because `RegionSubtypes` carries a `// Intel`
  line that would otherwise glue itself to the entry it precedes and hide
  `DescriptorRegion = 0`.
- **`itemTypeToUString`** (`types.cpp`): `case Types::X: return UString("Y")`
  pairs become the `typeNames` table.
- **`regionTypeToUString`** (`types.cpp`): `case Subtypes::X: return UString("Y")`
  pairs become the `regionNames` table, and are folded into the subtype table
  under the `Region` item type (the C++ answers a region's subtype by delegating
  to this function).
- **`itemSubtypeToUString`** (`types.cpp`): the `case Types::X:` blocks that
  answer directly with a name become the per-type subtype tables. The three
  delegations are skipped on purpose: `Region` (folded in from
  `regionTypeToUString`), and `File` / `Section`, which delegate to
  `fileTypeToUString` / `sectionTypeToUString` — tables that live in other files
  and are named at run time by the FFS and section type tables the parser
  already uses (`UEFITypeNames`).

## Failure modes

- **`error: parsed nothing; the repository files changed shape?`** — one of the
  three lookups or the `ItemTypes` enum no longer matches the expected form. The
  repository moved. Read the current `types.h` / `types.cpp`, update the regexes
  in `scripts/gen_uefi.py` to the new shape, and re-run. Do not loosen a regex
  until you have looked at what changed.
- **`error: subtype member ... appears in both ...`** — two `Subtypes` enums
  gained a member with the same name, which the flat `Sub` namespace cannot hold.
  This is a genuine conflict, not a bug in the script. Decide how the names
  should be disambiguated (the C++ keeps them apart by enum) before proceeding.
- **A build failure after a clean run** — the generated `Item` / `Sub` members
  the classification references (`UEFIItemClassification.swift`) changed name or
  disappeared. Reconcile the classification with the new tables; the
  classification is hand-written and outlives any single regeneration.
