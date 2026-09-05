# A shared pattern library — implementation plan

The reasoning is in `Design/FAVORITES_SYNC_IDEA.md`; this is what gets built and
in what order. The short version of the decision: the library becomes a **file**,
the file may live in a folder the user's own sync client watches, and the app
treats that file as **another writer** rather than as a place to put its list.

**In scope.** Entry identity, a library file, a three-way merge with conflict
resolution, the location setting, and the two dialogs the user meets.

**Not in scope.** `NSUbiquitousKeyValueStore` and CloudKit — both need an Apple
Developer Program team, an iCloud container and a provisioning profile, which
this app does not have (`CODE_SIGN_IDENTITY: "-"`). If that changes, KVS is a
later stage over the same merge, not a rewrite. Also out: sharing a library with
another person as a feature (copying the file already does it), per-file
libraries, and syncing the recents (a per-machine cache by design).

## The shape of it in code

The split follows the project's rule — anything that can be decided without a
window is decided in the package.

**`DumpCompareCore` (pure, no AppKit):**

| type | what it is |
|---|---|
| `SearchPatternEntry` | moves here from the app, gaining `id`, `sortKey`, `modifiedAt`, `device` |
| `PatternLibrary` | the document: entries, tombstones, and the version vector of who has written it |
| `VersionVector` | `[DeviceID: Int]`, with "is this a descendant of that" — how a concurrent write is told from a later one |
| `LibraryMerge` | `merge(base:ours:theirs:) -> (PatternLibrary, [Conflict])` — the whole rule set, as a function |
| `LibraryConflict` | what a rule must not decide: `bothEdited`, `editedAndDeleted`, `sameSearchTwoNames` |

**The app:**

| type | what it is |
|---|---|
| `LibraryFile` | read/write a `PatternLibrary` at a URL: `NSFileCoordinator`, atomic write, content hash of what was last read |
| `LibraryLocation` | whether the library is published to a shared file, and to which — a user-chosen URL behind a security-scoped bookmark (`SandboxBookmarkStore` already does this for dumps) |
| `FavoritePatternStore` | unchanged public face — `favorites`, `add`, `replace`, `existing`, `didChangeNotification` — now over a file instead of `UserDefaults` |
| `FavoritePatternsSettingsViewController` | gains the location line, the conflict line, and the two buttons |
| `LibraryAdoptionSheetController` | "this file already has patterns": merge / take the file / replace it |
| `LibraryConflictSheetController` | the resolver, one row per conflict |

The device id is a UUID minted on first launch and kept in `UserDefaults`. It is
per machine and never syncs — that is the point of it.

## The file

```json
{
  "format": 1,
  "vector": { "8B2C…": 14, "4E1F…": 9 },
  "entries": [
    { "id": "…", "name": "ME FPT", "pattern": "$FPT", "encoding": "ascii",
      "caseSensitive": false, "sortKey": 3.5,
      "modifiedAt": "2026-09-05T10:14:22Z", "device": "8B2C…" }
  ],
  "tombstones": [
    { "id": "…", "deletedAt": "2026-09-04T18:02:11Z", "device": "4E1F…" }
  ]
}
```

JSON because the argument for a file at all includes reading a diff of it.
`sortKey` is a fraction between neighbours rather than an array index, so a
reorder on one machine does not renumber every entry and collide with the other.
Tombstones make "you deleted it" distinguishable from "you never had it"; they
are dropped after a month, which is longer than any sync client takes.

### Which files exist, and what each one is for

The local file is the **truth**; the file in the synced folder is the
**medium**. That is the right way round, and not a matter of wording: a drive
can be unmounted, a file can still be downloading, another machine can be
writing it — none of which may stop the Find bar's menu from listing the
patterns. The app reads and draws the local file; the shared file is how two
machines tell each other what they know.

```
Containers/…/Application Support/DumpCompare/Favorites.json  ← the truth: what the UI reads,
                                                                with the base it was last agreed at
iCloud Drive/DumpCompare Patterns.json                       ← the medium (only once moved)
UserDefaults: the bookmark, this machine's device id, the migration flag
```

There is no copy in `UserDefaults`: the `FindFavorites` key migrates once, at
first launch after stage 2, and is then removed. What stays in the plist holds
no patterns.

**Truth and base are two roles, and they must not be the same bytes.** The base
is the last state agreed *with the shared file*; the truth is what this machine
believes now, which is ahead of the base whenever something has been added and
not yet published. Keep only one and the three-way merge loses its ancestor and
degrades to last-writer-wins — the thing this design exists to avoid. Keep them
in two files and a crash between the two writes leaves a base from one round
beside a truth from another. So: **one file, two sections, written atomically**.

```json
{ "format": 1, "local": { … }, "base": { … } }
```

`base` is absent until the library is moved out — with no other writer there is
nothing to have agreed with.

**The names say what is inside.** `Favorites.json` holds the favourites and
nothing else — not the recents, which are a per-machine cache, and not the
appearance or the file types, which stay in `UserDefaults`. A file called
`Library.json` would promise more than it holds, and something the app syncs
later should get a file of its own rather than be folded into this one. The
shared copy is `DumpCompare Patterns.json` instead: it is the one a stranger
sees, in a folder among other people's files, where the app's own word for the
feature says nothing and the content has to.

**The sync loop, both directions.** A local change writes `local`, then tries to
publish: merge `base`, `local` and the shared file, write the result there, set
`base` to it. An external change to the shared file runs the same merge. A
publish that cannot happen — drive not mounted, file busy — changes nothing but
the time of the next attempt; the truth is already safe locally.

**Which makes offline editing ordinary.** The earlier draft made the library
read-only while the shared file was unreachable, to avoid inventing a second
merge rule. With the base kept properly there is no second rule: edits made
while the file was away are one more concurrent writer, which is the case the
merge is for. Read-only stays only for an unresolved *conflict*, where the
question is the user's to answer.

**Use This Mac** drops the bookmark and the `base` section; `Favorites.json`
carries on as it always did.

## The merge, precisely

One function, and the table it implements — the tests are this table:

| ours vs theirs, against the base | outcome |
|---|---|
| neither changed an entry | keep it |
| one side changed it | that side |
| both changed it identically | that value |
| both added the same search (`isSameSearch`) | one entry |
| the order differs | the file's order leads; entries only this machine has are appended |
| a tombstone on one side, untouched on the other | deleted |
| **both changed the same entry differently** | `bothEdited` |
| **one edited, the other deleted** | `editedAndDeleted` |
| **both added the same search under different names** | `sameSearchTwoNames` |

A version vector decides whether the two are *concurrent* at all: a file whose
vector descends from ours is simply newer, and taking it is not a merge. Only
concurrent writes reach the table. Timestamps alone cannot answer that — two
Macs' clocks disagree by more than the sync window, and clock skew must not be
what decides which pattern survives.

## What is testable, and how

Almost all of it, without a window and without a network:

- **The merge**: base + two lists in, a list and a set of conflicts out. Every
  row of the table above is a test; the interesting ones are the three that must
  *not* be decided automatically, and a mutation that resolves them silently
  must fail.
- **The format**: a round trip, a file from the previous format, a file with a
  field this build does not know, a corrupt file.
- **The migration**: a `FindFavorites` array with today's shape becomes a
  library with ids.
- **`LibraryFile`**: two writers against one file, the second finding the hash
  changed and merging rather than overwriting.
- **The store**: the existing `FavoritePatternStoreTests` and
  `FavoritePatternsSettingsTests` (25 tests) must keep passing unchanged through
  stages 1–4 — the public face does not move.
- Only the two sheets need a window, and they are driven the way the project's
  other sheets are: `validate()` and `handleSubmit()` directly.

## Stages

Each ends with the app working and the suite green.

1. **Entry identity, in Core** (3–4 h). `SearchPatternEntry` moves into the
   package and gains `id`, `sortKey`, `modifiedAt`, `device`; decoding a row
   written by today's build mints them. Still stored in `UserDefaults`, nothing
   visible, 25 existing tests unchanged.
2. **The library becomes a file** (4–5 h). `PatternLibrary` + JSON codec;
   `Application Support/DumpCompare/Favorites.json` in the container becomes the
   truth the app reads and writes; one-time migration off the `FindFavorites`
   key; a corrupt or unreadable file keeps the last good copy and says so rather
   than presenting an empty list.
3. **The merge** (5–7 h). `VersionVector`, tombstones, `LibraryMerge`,
   `LibraryConflict` — the table above, in Core, with its tests. No UI, nothing
   calls it yet.
4. **Publishing, and watching the shared file** (4–5 h). The loop above: a local
   change writes the truth and then publishes it with a coordinated
   read-modify-write; the shared file is watched the way an open dump is
   (`FileChangeWatcher`), and what a merge brings back is announced through
   `didChangeNotification` — which every Find bar menu and the Favorites tab
   already follow. Exercised against a second file in the container before any
   of it can go wrong across machines.
5. **The location setting** (5–6 h). The Favorites tab says where the library
   lives; **Move…** is an `NSSavePanel` named `DumpCompare Patterns.json`,
   defaulting to iCloud Drive when it exists; a security-scoped bookmark
   remembers it; **Use This Mac** moves it back. Pointing at a file that already
   holds patterns opens the adoption sheet — merge (the default), take the file,
   or replace it (confirmed). An unreachable file changes nothing about what the
   app shows — the truth is local — beyond a line in the tab saying when the
   library was last published.
   **This is where syncing starts working**, for everything except a genuine
   collision.
6. **The resolver** (5–7 h). The tab grows `N conflicting changes — Resolve…`;
   the sheet lists one row per conflict — what this Mac says, what the file
   says, keep which, plus *Keep both* where the searches genuinely differ and
   *Keep all mine* / *Keep all theirs*. Nothing is written until it is answered,
   and the library is read-only meanwhile. `NSFileVersion` conflicts and
   `Patterns (1).json` siblings are folded into the same sheet and removed
   afterwards.
7. **Requirements and TODO** (1–2 h). §11 gains the library's location, the
   merge rule and the resolver; the TODO entry moves to Done.

**Cost: 27–36 hours.** Stages 1–4 are invisible and safe (16–21 h) and leave the
app with a file-backed library that is better tested than today's. Stage 5 is the
feature as a user would describe it. Stage 6 is the half that decides whether the
feature can be trusted, and it is not optional: a library that silently loses the
pattern you named on Tuesday is worse than one that lives on a single machine.

## Decisions taken

- **The local file is the truth, the shared file is the medium.** The app never
  draws from a file another machine may be writing, or that may not be there.
- **Truth and base live in one file, in two sections, written atomically** —
  different roles, and a crash must not leave them from different rounds.
- **Merge is the default at adoption**, replace is confirmed, and neither is
  silent.
- **The file's name wins** where both sides name the same search: this machine
  is joining the file.
- **Order is resolved by rule, never by dialog** — no one wants to be asked
  about row order.
- **Read-only while a conflict is unresolved**, so no half-merged list is ever
  saved. Nothing else makes the library read-only.

## Open questions

1. Whether the resolver should offer a third choice per row, "keep both as two
   entries", where the two are the same search under different names. It breaks
   the "one search, one entry" rule §11 states, and may still be what someone
   wants.
2. Tombstone lifetime: a month is the usual answer, and the cost of getting it
   wrong is a pattern that resurrects itself.
