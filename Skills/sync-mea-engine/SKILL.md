---
name: sync-mea-engine
description: Keep the Swift ME-firmware engine (Packages/MEFirmware) in step with upstream platomav/MEAnalyzer — detect drift between the upstream Python parser and the Swift port, categorize what changed, translate changed formats/logic into Swift, and reconcile the module's async API contract. Data (MEA.dat / Huffman.dat / FileTable.dat) is NOT synced here: the module fetches it live from the MEAnalyzer repo on first request and caches in memory. Use when the user asks to sync/update/refresh the ME/CSME/TXE/SPS/GSC engine from MEAnalyzer, after a new MEA release, to port a new upstream format change, or periodically to check whether MEAnalyzer's code moved. Invoke as /sync-mea-engine.
---

# Sync ME Analyzer Engine

ByteRipper's ME-firmware analysis lives in `Packages/MEFirmware`: a Swift
port of the parsing that upstream
[platomav/MEAnalyzer](https://github.com/platomav/MEAnalyzer) does in a single
~14k-line `MEA.py`, fronted by an **async API the UI calls**. This skill is
the repeatable way to keep that port current.

## Data is live, never stored

Upstream ships three databases — `MEA.dat` (firmware identification:
RSA-public-key hash → family/version/SKU/release), `Huffman.dat`
(decompression dictionaries), `FileTable.dat` (VFS module-name map). **The
Swift module does not ship or store them.** On the first analysis request it
fetches the three files fresh from the MEAnalyzer git repository and caches
them in memory for the run; on the next launch it fetches again. No disk
persistence, no bundled snapshot. See `reference/async-api.md` for the module
contract.

Consequence for this skill: **a `DB rN` revision upstream is not work for the
repo.** The module already picks it up at the next run. The only drift this
skill must act on is **code/format drift in `MEA.py`** — and, rarely, a change
to the *shape* of a `.dat` file (a new `MEA.dat` section or line grammar) that
forces the Swift parser to change. `check` still reports database revisions
informationally so you know what the module will load, but a data-only change
produces no Swift diff.

## What lives where

| Path | Role |
|---|---|
| `Packages/MEFirmware/Sources/MEFirmware/` | Swift engine + the UI-facing result model (`Models/FirmwareAnalysis.swift`) + the async data provider (`Data/`) |
| `Packages/MEFirmware/Sync/mea-sync-state.json` | Baseline: the upstream commit whose code the port mirrors (metadata only — never data) |
| `Packages/MEFirmware/Sync/mea-sync-report.json` | Machine-readable report of the last `check`/`sync` run |
| `Skills/sync-mea-engine/reference/async-api.md` | The module's async external API + live-data loading contract |
| `Skills/sync-mea-engine/reference/result-model.md` | The "structured output for UI": the canonical `FirmwareAnalysis` contract. Do not break it |
| `Skills/sync-mea-engine/reference/upstream-map.md` | Symbol-level map of `MEA.py` → Swift-engine concepts; keep it current as you port |

If `Packages/MEFirmware` does not exist yet, run `bootstrap` first. The
upstream source defaults to the sibling clone `../MEAnalyzer` (a full git
clone of `platomav/MEAnalyzer`); override with `MEA_UPSTREAM_PATH`.

## The module contract in one screen

- **Async external API.** The module exposes `async` entry points to the app
  (analysis of a region/file), never blocking a UI thread; heavy parsing runs
  off the main thread (actor).
- **Lazy single-flight load.** The first call that needs the databases kicks
  off one shared fetch of the three files from the MEAnalyzer repo; concurrent
  callers wait on the same task, not three requests. Cache is in-memory only.
- **No disk cache.** Next launch re-fetches fresh data.
- **Finish-after-data.** The parser runs structure decoding first (it needs no
  DB); when identification needs `MEA.dat`, it awaits the provider, then
  **continues the same analysis to completion** — no re-parse of the file. If
  the fetch fails, the module reports a typed error (offline / bad response /
  rate-limited), mirroring `GuidsSourceError` in `Modules/UEFITool/…/GuidsSource.swift`.

Mirror the app's existing `GuidsSource`/`LongSoftGuidsRepository` pattern for
the data provider: a `Sendable` protocol so tests install a stub and never
touch the network. `reference/async-api.md` spells out names and shapes.

## Modes

`bootstrap` — one-time: scaffold `Packages/MEFirmware` (Package.swift, engine
layout mirroring `Packages/UEFIImage`, tests), write the canonical result
model from `reference/result-model.md`, the async data provider from
`reference/async-api.md`, and pin the baseline to current upstream. The *first
full port* of the core (FPT → manifest → $CPD → identifying lookups) is an
incremental effort driven by this skill's mapping; bootstrap lays the skeleton
and ports the spine, later runs port the rest and then only keep it in sync.

`check` (default) — **read-only on the Swift package.** Fetch upstream, diff
`state.baselineSHA..HEAD`, classify every change, emit `mea-sync-report.json`,
print a summary. Database revisions are informational. Never edits Swift.

`sync` — apply mode, **code only**. Port changed formats/logic into Swift per
the taxonomy below, build + test, then pin the baseline. Nothing is written
for database revisions (the module loads them live). Review what the model
changed before committing; this mode is a diff, never a blind rewrite.

`baseline` — re-pin the state to a chosen upstream commit (used after a manual
reconcile).

## Run

Everything resolves from `Skills/sync-mea-engine/scripts/mea_sync.py` and can
be run from any directory:

```bash
python3 Skills/sync-mea-engine/scripts/mea_sync.py check   # default, read-only
python3 Skills/sync-mea-engine/scripts/mea_sync.py check --json out.json
python3 Skills/sync-mea-engine/scripts/mea_sync.py sync
python3 Skills/sync-mea-engine/scripts/mea_sync.py bootstrap
python3 Skills/sync-mea-engine/scripts/mea_sync.py baseline --sha <upstream-sha>
```

Flags: `--no-fetch` (work offline against the local clone; accepted on either
side of the subcommand), `--source <path>`
and `--app-root <path>` override the resolved upstream clone and ByteRipper
root, `--pkg <path>` overrides the engine package. The script is stdlib-only
and deterministic; run it yourself (python3 is allowed in this project).

The report and state JSON are the contract between the script and the model.
The model reads `mea-sync-report.json`, but must open the **real upstream
diff** (`git -C ../MEAnalyzer diff <baseline>..HEAD -- MEA.py`) before
writing any Swift — the report's change index is a heuristic reducer, not a
substitute for reading.

### How the report names a change

`MEA.py` keeps only its first ~10.5k lines inside a `class`/`def`; the
remaining ~3.4k are module-level — the lookup tables, the anchor regexes, and
the per-file analysis loop that upstream's whole default output is printed
from, which is also the region this port leans on hardest (`eng_fw_end`, the
firmware-type and release passes, the per-variant blocks). Keyed by top-level
symbol alone that tail collapses into whichever `def` comes last, so the
script segments it as well, using the structure upstream already wrote into
the file rather than a phase list kept here (which would rot at the next
release):

| Key | Opened by |
|---|---|
| `class:X` / `def:x` | a column-0 `class`/`def`, as before |
| `module:<comment>` | a column-0 comment — the table and regex sections |
| `main:<comment or condition>` | inside a column-0 compound statement (the analysis loop, the CLI ifs): every indent-4 comment or block-opening compound |

Every line of the file belongs to exactly one segment. A compound opening
directly under its own comment continues that comment's segment (the comment
is the better name); a one-line `elif` chain row opens nothing (it is a table
row, not a phase); a bare `else`/`except` borrows the label of the chain it
continues. Names are elided in the middle, because upstream edits its comment
text at the end.

`code_locations` then attributes each hunk of the range to the segment holding
it, so a run points at `11419-11453  main:Detect Intel Engine/Graphics/…`
rather than at a name three thousand lines away. A segment renamed upstream
(its anchor comment reworded) shows up as one `code_added` plus one
`code_removed` with the same line range — that is the honest reading, not a
bug.

## Change taxonomy → action

`mea_sync.py` classifies each upstream change; act on the class:

| Upstream change | Kind | Action |
|---|---|---|
| Lines added inside `MEA.dat` / `Huffman.dat` / `FileTable.dat` only | **data** | **No repo action.** The module fetches these live; the next run has them. If a *new grammar* appears (new line format, new section) that the Swift `MEADatabase` parser cannot read, that is a parser change — port it like `code`. |
| A new `MEA.py` segment or class added | **format** | Port the new structure(s) (see Porting). New CSE generation usually = new `MN2_Manifest_R*`, `CPD_Header_R*`, `CSE_Ext_*` decode + a version-dispatch case. |
| `MEA.py` segment *changed* | **logic/format** | Read the hunk diff; port the delta. If it only widens a branch table (a `get_variant`-style elif, a SKU/platform mapping), mirror it — prefer a Swift lookup table over a new if-chain so the next port is data. |
| `MEA.py` segment removed | **removal** | Delete the Swift counterpart and its tests; confirm nothing else referenced it. |
| `Changelog.txt` / `README.md` only | **noise** | Record, no code action. New firmware families listed there but not yet in code are a heads-up, not a change to port yet. |
| Crypto/checksum core (`rsa_sig_val`, `pss_*`, hashes) changed | **crypto** | Effectively never. If it does, port carefully — it is the least-testable part; validate against a real signed firmware. |

Report fields (`db`, `code_added`, `code_changed`, `code_removed`, `noise`)
map 1:1 to this table, and `code_locations` says where each of them landed. A
`db`-only report means a clean sync: nothing to port.

## Porting a change (model work)

Conversion rules that keep a port cheap and faithful:

- **Layout structs.** `ctypes.LittleEndianStructure` classes in MEA.py are
  plain little-endian byte layouts. Port them as a Swift decoder over a
  `Data` slice (see how `UEFIImage` decodes structures), one type per
  upstream class, fields in order. Keep upstream's hex offsets in comments —
  they are the cross-check when a revision bumps a layout.
- **Container finders.** Upstream regex-anchors (`$FPT`, `$CPD`, `$MN2`,
  BPDT, PCIR …) locate structures inside a region. ByteRipper already has a
  UEFI/IFWI tree — reuse its region offsets where the region is a BIOS/IFWI
  container, and only fall back to pattern scanning inside a raw ME region.
- **Identification.** Family/variant is decided in `MEA.py` `get_variant`:
  manifest RSA-public-key SHA-256 looked up in the *live-fetched* `MEA.dat`,
  with module-name heuristics as fallback. Port the lookup against the data
  provider faithfully; port the fallback heuristics as a small, clearly named
  table. The identification step runs **inside** the analysis pipeline and
  awaits the data provider (reference/async-api.md), then continues.
- **Version/sku/date fields** come from parsed manifest fields, not the DB.
  Keep MEA.py's precedence and its `0x` sentinels exactly.
- **Decompression/crypto** are algorithms with no upstream data dependency
  (Huffman *dictionaries* are data, fetched live in `Huffman.dat`). Port once,
  test against known vectors.
- **UI/CLI code in MEA.py** (`mea_*`, `mass_scan`, parameter handling) is
  replaced by ByteRipper's own UI. Do not port it.

**Result-model stability.** The UI binds to
`Models/FirmwareAnalysis.swift` (reference/result-model.md). A sync may add
fields or enums — never rename or remove them; bump `EngineModelRevision` when
the model grows so the UI can adapt deliberately.

## After a run

1. **Review the diff you wrote** — engine + tests + state together are one
   unit of change. A state bump without a diff is wrong; a data revision in
   the report is *expected* to produce no diff.
2. **Build and test** the package and whatever imports it:
   ```bash
   cd Packages/MEFirmware && swift build && swift test
   ```
3. **Confirm the baseline is clean:** re-run `check` — it should report no
   remaining `code_*` items (a fresh `db` revision is fine).
4. **Update `reference/upstream-map.md`** for every symbol you ported or
   deleted, so the next sync starts from a true ledger.
5. Commit when the diff is sound.

## Failure modes

- **`upstream clone not found`** — set `MEA_UPSTREAM_PATH` or pass `--source`;
  a full clone of `platomav/MEAnalyzer` is needed for diffing (raw-file
  fetching cannot see history).
- **No baseline yet / stale baseline** — `mea-sync-state.json` missing or the
  baseline SHA is not an ancestor of `HEAD`: run `bootstrap` (first time) or
  `baseline` after a manual reconcile. Never guess a baseline.
- **`code_changed` huge or empty parse** — the change index heuristics failed
  or upstream restructured the file; read the real diff and update the
  script's segmenter, then re-run. Do not loosen it blind. The cheap sanity
  check is coverage: every line of `MEA.py` must fall in exactly one segment,
  and no segment should be named for a keyword alone.
- **New CSE generation with an unknown RSA key** — no DB entry and no
  module-name match: this is genuinely new format knowledge. Port the structs
  and add the fallback branch by hand; the live DB alone cannot tell you the
  layout. That is exactly what a "format" change means.
- **`swift build` broken after a clean run** — a renamed/removed model field
  or classification symbol. Reconcile references before touching the parser.
- **Runtime data fetch fails in the app** — that is the module's async
  contract (typed offline/rate-limit error, UI surfaces it), not a sync
  problem. Do not "fix" it by snapshoting data into the repo; keep the module
  fetching live.
