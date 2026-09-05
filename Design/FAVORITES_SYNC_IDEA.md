# Syncing the pattern favourites between machines

Taking apart a question, not proposing a plan. The favourites (§11,
`Design/PATTERN_LIBRARY_IDEA.md`) are the first thing in the app that is
*knowledge* rather than a preference: `ME FPT`, `Aptio capsule header`, the
marker you worked out on a Tuesday afternoon and want on the laptop next to the
programmer on Friday. Everything else in `UserDefaults` — the font, the row
pitch, the recents — is about one machine's screen and can stay there.

## The fact that decides most of it

The app is signed **ad-hoc**: `CODE_SIGN_IDENTITY: "-"`, `TeamIdentifier=not
set`, and three entitlements — the sandbox, user-selected files, app-scope
bookmarks.

Every iCloud mechanism (A, B, C below) needs, without exception:

- membership in the Apple Developer Program, for a Team ID;
- an iCloud container registered to that team;
- a provisioning profile carrying the iCloud entitlement, embedded in the `.app`;
- Developer ID signing and notarisation, since the app is handed out as a DMG
  rather than through the App Store.

Without those the entitlement is not honoured at launch: `NSUbiquitousKeyValueStore`
accepts writes and syncs nothing, and the ubiquity container URL comes back nil.
There is no partial credit and no way to test the real path locally.

So the first question is not technical. **If the Developer Program is not in the
picture, only option D exists** — and D is worth having anyway.

## The options

### A. `NSUbiquitousKeyValueStore`

Key-value storage shared between a user's machines, delivered by iCloud without
any code touching the network.

- *For*: the favourites are already an array of dictionaries under one key. KVS
  is the same shape, one layer out. No schema, no account UI, no error states to
  design, no fetch to wait for. Its limits — 1 MB total, 1024 keys — are three
  orders of magnitude above a list of named patterns (~100 bytes each). Changes
  arrive as a notification, which is exactly how the favourites already reach
  every reader (`FavoritePatternStore.didChangeNotification`).
- *Against*: last-writer-wins per key, so the merge is ours to design (below).
  And it is iCloud-only: no Dropbox, no git, no copying a file to a colleague.

### B. CloudKit private database, a record per pattern

- *For*: a real merge, per-record change tokens, subscriptions, history.
- *Against*: a schema, an account state to handle (not signed in, restricted,
  quota), network errors surfaced in a UI that has none today, and asynchronous
  reads where the list is currently a synchronous property. Enormous for a list
  of short strings whose upper bound is "as many as a person can name".

### C. A document in the ubiquity container

A JSON file synced by iCloud Drive, read and written through `NSFileCoordinator`
with an `NSFilePresenter` for changes and `NSFileVersion` for conflicts.

- *For*: a human-readable file, conflicts exposed as versions rather than
  silently resolved, and the same file can be exported.
- *Against*: file coordination is the fiddliest of the three to get right, and
  the conflict UI is a feature of its own. It buys, over A, only what D buys —
  a file — and D needs no entitlement at all.

### D. A library file in a folder the user picks

An export/import pair, and — the interesting half — the option to *keep* the
library in a file the user chose: an `NSOpenPanel`, a security-scoped bookmark
(the app already has `files.bookmarks.app-scope` and
`files.user-selected.read-write`, and `SandboxBookmarkStore` already does this
work for dumps), the file watched for changes the way `FileChangeWatcher`
watches an open dump.

- *For*: works today, with today's signature and today's sandbox. If the folder
  is in iCloud Drive, iCloud syncs it; if it is in a git repo, git does; if it
  is on a stick, the stick does. The app is not in the sync business at all.
  It also answers "let me put my patterns under version control" and "send me
  your ME patterns", which no iCloud option answers.
- *Against*: the user has to choose a place, which A does not ask. Two machines
  writing the same file at the same moment is a conflicted file, resolved by
  whatever syncs it — acceptable for a list one person curates, unacceptable if
  this were a shared team library.

**Recommendation.** D first, whatever happens with the Developer Program: it is
small, it is useful on its own, and it does not become dead code if A arrives.
Then A, if and when the app is signed with a team — A is the one that needs no
decision from the user at all, which is the right end state for something this
small.

## Where the file goes, under the sandbox

Two locations, and they answer different questions.

**The app's own copy: the container.** `Application Support/DumpCompare/Patterns.json`,
reached the ordinary way — `FileManager.default.url(for: .applicationSupportDirectory,
in: .userDomainMask)`, which inside a sandboxed app already resolves to
`~/Library/Containers/dev.maxik.DumpCompare/Data/Library/Application Support`.
No entitlement, no panel, no bookmark, correct on first launch, and it is the
place Apple's own guidance names for data the app maintains on the user's behalf
that is not a document. The subfolder is not redundant: that directory already
holds folders the system puts there (`AddressBook`, `CrashReporter`, `iCloud`),
and ours should sit together.

This copy is **the store** — the file the app reads at launch and writes on every
change — rather than a mirror of `UserDefaults`. Two stores on one machine means
a merge between them, which is the same problem as syncing, indoors and for no
reason. The existing `FindFavorites` key migrates once and is then ignored.

**The user's copy: wherever they say.** An `NSSavePanel` for "keep my library
here", a security-scoped bookmark to come back to it — both entitlements are
already in place (`files.user-selected.read-write`,
`files.bookmarks.app-scope`), and `SandboxBookmarkStore` already does exactly
this for dumps. The panel's `directoryURL` can be pre-set even where the app
cannot read the folder itself, because the panel runs out of process: default it
to `~/Library/Mobile Documents/com~apple~CloudDocs` when that exists — the folder
Finder shows as iCloud Drive — and to `~/Documents` otherwise. That is as close
to "the sensible default" as a sandboxed app can get without an iCloud
entitlement, and it puts the file where the user's own sync already runs.

**Where it must not go.** `~/Documents` or a dotfile in the home directory
written without a panel: unreachable from the sandbox, and the workaround is a
temporary-exception entitlement, which is a way of saying the design is wrong.
A group container needs a Team ID, which is the thing we do not have. And the
ubiquity container is option C, with its entitlement.

**The name and the format.** One format for both copies, so "keep it here",
"export" and "import" are one code path: JSON, because the argument for a file at
all includes reading a diff of it. The user's copy is offered as
`DumpCompare Patterns.json` — a name recognisable in a folder of other people's
files.

**Details that will bite.**

- Write atomically, and through `NSFileCoordinator` for the user's copy: a file
  in iCloud Drive or Dropbox has another process writing it too.
- An iCloud Drive file may not be downloaded yet;
  `FileManager.startDownloadingUbiquitousItem(at:)` is the difference between
  "empty library" and "wait a moment".
- The user's copy can be unavailable at launch — volume not mounted, sync not
  finished. Fall back to the container copy and say so in the Favorites tab
  rather than presenting an empty list, which reads as "everything is gone".

## The setting: moving the library out of the container

The Favorites tab says where the library lives, in one line, and offers to move
it:

```
Library:  This Mac (Application Support)          [ Move…]
Library:  iCloud Drive / DumpCompare Patterns.json [ Move…] [ Use This Mac ]
```

**Move…** is an `NSSavePanel` named `DumpCompare Patterns.json`, opening on
iCloud Drive when it exists. Any folder a sync client watches works the same
way and needs nothing extra from us: iCloud Drive, and — since macOS 12.3 —
Google Drive and Dropbox, which mount under `~/Library/CloudStorage/`. The
sandbox lets us in because the user pointed at it, not because of where it is.

**A move transfers authority, not a copy.** From then on the chosen file *is*
the store: read at launch, written on every change, watched for changes the way
an open dump is (`FileChangeWatcher`), so a rename made on the laptop reaches
this machine's Find bar menus through `didChangeNotification` like any local
edit. The container file stays behind as a last-known-good copy, not as a second
library.

**Pointing at a file that already has patterns** — which is what setting up the
second machine *is* — is the one moment two libraries meet, and it must not
silently overwrite either side. The answer is **merge, offered rather than
assumed**:

- *Merge* (the default, and the case that actually happens): the desk Mac has
  twelve patterns, the laptop three, and the point of syncing is to have
  fifteen. The rule, stated in one sentence: entries that ask the same thing of
  a file are one entry — `isSameSearch`, or the id once entries have one — the
  file's order comes first with this machine's own entries appended, and where
  both name the same search the **file's** name wins, because this machine is
  joining the file.
- *Use what is in the file* — discard this machine's list. Right when it holds
  nothing worth keeping, and the honest way to say "start from the shared one".
- *Replace the file with this Mac's* — the only destructive answer, so it exists,
  it is never the default, and it asks again.

That moment is not special, though — see the next section. A shared file is not
a lock, and merging is what every write does, not what adoption does once.

**When the file is not reachable** — drive not mounted, sync not finished, the
file deleted from under us — the library falls back to the container copy and
the tab says so. Whether it is read-only there is a choice: read-only keeps the
number of ways two lists can diverge down while the merge is being built, and
once the three-way merge below exists there is no reason to forbid the edits —
they are one more concurrent writer, which is the case the merge is for anyway.

**Use This Mac** moves it back: copy the current contents into the container,
forget the bookmark, stop watching.

What stays in `UserDefaults` is the bookmark and nothing else — the patterns
themselves live in whichever file is the store.

## Conflicts are the ordinary case

The tempting claim is that once both machines point at one file there is nothing
to merge: they read and write the same bytes. That is wrong, and it is the
mistake this section exists to correct. **A synced file is not a lock.** Between
this machine's write and the other machine seeing it there are seconds to
minutes, and in that window the other machine is editing a copy that is already
stale. Nothing warns either of them.

What the sync client does with that varies, and none of the outcomes is
"resolved":

- **iCloud Drive** keeps one version current and files the other as an
  `NSFileVersion` conflict, waiting for someone to resolve it.
- **Dropbox, Google Drive** leave a sibling: `Patterns (1).json`,
  `Patterns (conflicted copy).json` — which no one reads unless an app looks.
- Some clients, on some paths, simply keep the last writer. The earlier edits
  are gone with no trace at all.

So the app cannot treat the file as a place to put its list. It has to treat it
as *another writer* — and that means three things.

### 1. Every write is a read-modify-write, coordinated

Under `NSFileCoordinator`: re-read the file, merge our changes into what is
there now, write the result atomically. Plus an optimistic check — the content
hash we last read — so a write that finds the file changed underneath merges
instead of overwriting. That alone removes every conflict except the genuinely
concurrent ones, and those are the interesting ones.

### 2. A three-way merge, with the container copy as the base

This is what the copy left behind in the container is *for*, and it is worth
more than a fallback for an unmounted drive: it is the **last state both sides
agreed on**. With a base, most apparent conflicts are not conflicts at all —
if only one side changed a field since the base, that side's value is simply
the answer, and nobody has to be asked.

| ours vs theirs, against the base | resolution |
|---|---|
| only one side changed an entry | that side, silently |
| both changed it the same way | it, silently |
| both added the same search | one entry, silently |
| entries neither side touched | kept, silently |
| both changed the same entry differently | **ask** |
| one edited, the other deleted | **ask** |
| both added the same search under different names | **ask** (one entry, two names) |
| the order differs | never asked: the file's order leads, entries only this machine has are appended |

For that to be decidable each entry needs, beside its `id`: `modifiedAt`, the
device that wrote it, and — for deletions — a tombstone (`deletedAt`) rather
than absence, so "you deleted it" is distinguishable from "you never had it".
Timestamps alone cannot tell a *later* edit from a *concurrent* one, so each
write also carries a small version vector (`{device: counter}`); a file whose
vector is not a descendant of ours is a concurrent write, and that is the
signal to merge rather than to trust the newer timestamp. Clock skew between
two Macs is otherwise exactly the thing that decides which of your patterns
survives.

### 3. A resolver the user actually meets

When the merge reaches a case in the "ask" rows, the library stops being
something the app can decide alone:

- **Nothing is written until it is resolved.** The library goes read-only for
  that moment, the way an unreachable file makes it read-only — one rule, not
  two — and no half-merged list is ever saved.
- **It is not a modal that jumps in front of the user.** Conflicts arrive when
  the sync client delivers, which may be in the middle of a search of an 8 MB
  dump. The Favorites tab grows one line — `2 conflicting changes — Resolve…` —
  and the Find bar's menu keeps working on the last agreed list. The sheet opens
  when the user says so, and offers itself once when they open the tab.
- **The sheet is per entry, not per file.** One row per conflict: what this Mac
  says, what the file says, and which to keep — plus *Keep both* where the two
  are genuinely different searches, and *Keep all mine* / *Keep all theirs* for
  someone who knows which machine was right and does not want six questions.
  A deletion against an edit reads as what it is: "deleted on the laptop,
  renamed here".
- **Conflicted siblings are folded into the same resolver.** `NSFileVersion`'s
  unresolved conflicts and a `Patterns (1).json` sitting beside the file are two
  spellings of one thing: on load, all candidates are merged against the base,
  and whatever cannot be decided goes into the same sheet. Then the siblings are
  removed, which is the only way they ever get read.

### What this costs

It is most of the work of the feature, and it is the part that cannot be
skipped: a library that silently loses the pattern you named on Tuesday is
worse than one that lives on a single machine. The consolation is that all of
it is testable without a window and without a network — a base, two lists, a
merge function, and a table of cases — which is where this app puts its
confidence anyway (`DumpCompareCore`).

## What the model would have to change

One thing, and it is the same for A, C and D:

**A favourite needs an identity of its own.** Today it is identified by what it
*is* — pattern, encoding, case rule (`isSameSearch`) — which is right for
"do not keep the same search twice" and wrong for syncing, on exactly two
operations:

- **Rename**: with identity-by-content, renaming looks like deleting one entry
  and adding another. Two machines renaming the same pattern differently end up
  with two entries.
- **Delete**: a naive union of two lists resurrects everything either side
  deleted, because "absent" and "deleted" are indistinguishable.

So: a UUID per entry, stored alongside the fields, and — for A — one KVS key per
entry (`fav.<uuid>`) rather than one key for the list, which makes concurrent
adds and renames safe under per-key last-writer-wins. Deletions need a tombstone
(the id plus a timestamp) kept long enough for the other machine to see it.
Reading stays backwards compatible: a stored row without an id gets one when it
is read, which also gives the migration for free.

Order within the list is the user's (§11), and order is a property of the *list*
rather than of an entry — so it wants a sort key per entry (a fractional index,
or just a float between neighbours) rather than an array position, or the two
machines will fight over a reordering.

## What it would do to the running app

Most of this is already paid for:

- `FavoritePatternStore.didChangeNotification` is the single channel every
  reader uses — each window's Find bar menu and the Favorites tab. A change
  arriving from iCloud lands the same way a local edit does, and both already
  work.
- The Favorites tab already refuses to re-read the list while a draft row is
  being filled in, which is the same protection an external change needs.

What is new:

- **Merge, not replace.** Every reader today re-reads the whole list; a sync
  change has to be merged into it, not written over it, or a rename on this
  machine loses to a stale copy from the other.
- **Arrival at any moment.** A change can land seconds or minutes after the
  other machine made it, including while the user is editing a row in the tab.
  Rows must not jump under the hands: the tab redraws what changed, and leaves
  the row being edited alone until it commits.
- **Nothing may block.** The list is a synchronous property today and should
  stay one — the local copy is the truth the UI draws, and sync updates it.
- **Off, or offline, is a normal state.** Everything works locally with iCloud
  disabled; the tab says where the library lives in one line, and nothing else
  changes.
- **A test seam.** `FavoritePatternStore.defaults` is swappable so tests do not
  write the user's own; the sync layer needs the same — a protocol over KVS (or
  over the file), so the suite never touches a real iCloud account.

## What is deliberately not synced

- **The recents.** A cache of what was typed on *this* machine, capped at ten
  and evicted constantly. Syncing it would mean the laptop's noise evicting the
  desk machine's, for no gain.
- **Appearance, layout, word size, file types.** Preferences about one screen
  and one system.
- **Bookmarks.** Session-only by design (§20), and about a file rather than
  about a class of dumps.

## Open questions

1. Is the Developer Program in the picture at all? Everything above splits on
   this.
2. If D: is the library file *the* store (the app reads and writes it directly)
   or a copy the app syncs into `UserDefaults`? The first is simpler to reason
   about and puts the file's availability on the critical path.
3. Tombstone lifetime — a month is the usual answer for a list this size, and
   the cost of getting it wrong is a resurrected pattern. It applies to the file
   as much as to KVS: a tombstone dropped before the other machine has seen it
   is a deletion that undoes itself.
4. Does a synced library want a per-entry "where it came from" (this machine,
   imported, shared)? Probably not; a name that cannot say it is a name that
   needs improving.
