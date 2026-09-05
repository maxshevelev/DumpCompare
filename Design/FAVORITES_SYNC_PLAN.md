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
                                                                with a base per machine beside it
iCloud Drive/DumpCompare Patterns (A93F1C0D22B7).json        ← the medium: this Mac's own file
iCloud Drive/DumpCompare Patterns (5E1C7740B903).json           … and the other machines',
                                                                read but never written
UserDefaults: the bookmark, this machine's device id, the migration flag
```

There is no copy in `UserDefaults`: the `FindFavorites` key migrates once, at
first launch after stage 2, and is then removed. What stays in the plist holds
no patterns.

**Truth and base are two roles, and they must not be the same bytes.** A base
is the last state agreed *with one other machine's file*; the truth is what this
machine believes now, which is ahead of every base whenever something has been
added and not yet published. Keep only one and the three-way merge loses its ancestor and
degrades to last-writer-wins — the thing this design exists to avoid. Keep them
in two files and a crash between the two writes leaves a base from one round
beside a truth from another. So: **one file, two sections, written atomically**.

```json
{ "format": 1, "local": { … }, "bases": { "DumpCompare Patterns (…).json": { … } } }
```

One base per machine, because there is one file per machine: what this Mac last
agreed with the laptop says nothing about what it last agreed with the desk.
`bases` is empty until the library is moved out — with no other writer there is
nothing to have agreed with.

**The names say what is inside.** `Favorites.json` holds the favourites and
nothing else — not the recents, which are a per-machine cache, and not the
appearance or the file types, which stay in `UserDefaults`. A file called
`Library.json` would promise more than it holds, and something the app syncs
later should get a file of its own rather than be folded into this one. The
shared files are `DumpCompare Patterns (<Mac> <id>).json` instead: the name is
the one a stranger sees, in a folder among other people's files, where the app's
own word for the feature says nothing and the content has to. The Mac's name is
there so a person can tell the files apart, and the head of its device id so two
Macs called the same thing cannot collide — which would put us back to one file
with two writers.

**The sync loop, both directions.** A local change writes `local`, then tries to
publish: for each machine's file in the folder, merge that machine's base,
`local` and the file, and set the base to what was read; then write **this
machine's own file** if what it says has changed. An external change to any file
in the folder runs the same round. A
publish that cannot happen — drive not mounted, file busy — changes nothing but
the time of the next attempt; the truth is already safe locally.

**Which makes offline editing ordinary.** The earlier draft made the library
read-only while the shared file was unreachable, to avoid inventing a second
merge rule. With the base kept properly there is no second rule: edits made
while the file was away are one more concurrent writer, which is the case the
merge is for. Read-only stays only for an unresolved *conflict*, where the
question is the user's to answer.

**Keep on This Mac** drops the bookmark and the `bases` section; `Favorites.json`
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
   remembers it; **Keep on This Mac** moves it back. Pointing at a file that already
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

## What the build changed about this plan

**All seven stages are built** (branch `favorites-sync`). Each ended with the
app working and the suite green; what each one settled is in its commit. Four
things the plan did not know:

1. **One shared file was the mistake**, and stage 8 undoes it — see below. The
   plan's "fold in the copies a sync client leaves behind" went with it: the app
   no longer reads, absorbs or removes anything a provider leaves in the folder.
   Taking part in a provider's conflicts was what one file with two writers
   forced; with one file per machine there are none to take part in, and a file
   a provider could not decide about is the user's to look at.
2. **The question lands on whichever machine syncs second.** The first published
   and knows nothing about the second's version, so the second is the one that
   discovers the disagreement, answers it, and publishes the answer for the
   first to take. That is not a flaw in the window — it *is* the window — but
   it decides what a test fixture has to do, and it is worth knowing before
   reading a bug report that says "the conflict appeared on the wrong Mac".
3. **The library is one file, not two.** The plan had `Favorites.json` and
   `Base.json`; the two roles are real but they must be written together, or a
   crash leaves a base belonging to a different round than the truth beside it.
   One file, two sections.
4. **The store had to keep working exactly as it was.** Everything above sits
   under `FavoritePatternStore`'s existing face — `favorites`, `add`,
   `replace`, `existing`, `didChangeNotification` — which is what let five
   stages land without touching the Find bar, its menu, or the 144 tests around
   them.

The only visible change to the plan's shape: what the plan called "the store"
in a synced folder is called **the medium** here, and the local file is the
truth. The reasoning is in the idea document; the code never had it the other
way round.

## Stage 8: one file per machine

Two Macs sharing one file made the sync provider the arbiter of who won, and it
arbitrated badly. Measured, with the network pulled on one machine and both
edited: iCloud kept one version and discarded the other **without producing a
conflicted copy** — so nothing was left for the app to fold in, no question
could be raised, and the losing machine's patterns were simply gone. Every
app-level rule above is correct and none of it can survive a version that never
arrives.

So no file is ever written by two machines:

- This Mac writes exactly one file in the folder, named after a hash of its own
  id — an id taken from the hardware, because a *hostname* moves (a laptop takes
  one from whatever network it joins) and a file named after something that
  moves is a machine that starts writing a second file and abandons the first.
  Which Mac wrote it is inside the file, where a rename is a changed line.
- It reads **every** library file there and merges each into its own library,
  with the same three-way merge, version vectors and tombstones — one base per
  file.
- It never writes, deletes or renames another machine's file. Adoption's
  "replace what is there" is carried out with tombstones, which is a thing the
  other machines honour, rather than with a write they cannot see coming.
- Only a machine's own file is a library file. The single `DumpCompare
  Patterns.json` this branch started with is not read, written or removed — it
  is one more thing in the folder that is not one of these. (It *was* absorbed
  as a peer for a while; both machines have since taken what it held, so the
  code for it went the way of the copies.)

Two rules had to change with it, and they are what makes a race behave the way
anyone would expect:

- **A machine that is asking still publishes its own file.** The file is that
  machine's own belief, not a half-merged list, so holding it back only kept the
  other Mac unaware — carrying on with a version this one had already disagreed
  with. Published, both machines see both versions and **both are asked**.
- **An answer on one machine settles the other.** What carries it is the
  counters: a machine folds another's into its own only when it has *accepted*
  that version, which is exactly what answering does. So a file whose counters
  cover everything this machine wrote was written by a machine that saw this
  one's version and decided — and this machine takes it, question and all. A
  machine that is merely asking never folds them in, so it can never claim that
  by accident; and this is why the file is written when only the counters have
  moved, which is what "keep my version" changes and nothing else.

The old rule — "a standing question is never answered by counters" — was the
single shared file's, where counters could travel without the content they
belonged to. Here they cannot.

## What the signature had to do with it

The library stopped syncing after every rebuild, and nothing about the library
was wrong: it could not write.

A security-scoped bookmark is bound to the app's **code identity**. Ad-hoc
signing (`CODE_SIGN_IDENTITY: "-"`) has no certificate, so that identity is the
binary's own hash — measured across one rebuild here, `2a6a6b…` became
`a9fe7a…`. Every build therefore threw away every folder the user had granted,
and the only grant left was the one the save panel had given for the session it
was pressed in. That is why syncing worked immediately after choosing the folder
and was dead by the next launch.

Signing with an **Apple Development** identity ends it, and the reason is
visible in what the system checks:

```
designated => identifier "dev.maxik.DumpCompare" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: … (…)" …
```

That is the same sentence after every build — the identity is the *certificate*,
not the bytes — so a bookmark taken today is still valid tomorrow.

The team an identity belongs to is **personal, and not the repository's
business**: `Signing.xcconfig` optionally includes a `Signing.local.xcconfig`
that git ignores, one line per machine, and the committed file says how to find
the value. Without it the build falls back to ad-hoc signing — it runs, and only
the folder permission stops surviving rebuilds.

It is also the first half of the entitlement story the idea document describes:
a team is what iCloud's own mechanisms need, should they ever be wanted.

## Decisions taken

- **The local file is the truth, the folder is the medium.** The app never
  draws from a file another machine may be writing, or that may not be there.
- **One file per machine, written by that machine alone**, so a sync provider
  never has to decide between two versions of one file — the decision it made
  silently, and wrongly, is what this replaces.
- **Nothing a provider leaves behind is touched**: not read, not folded in, not
  removed.
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
