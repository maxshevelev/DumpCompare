# A library of named patterns — an idea, thought through

Not a plan. On a bench the same handful of byte sequences is searched for over
and over — a header's magic, a region's signature, the string a vendor puts in
front of a table — and today the only place the app remembers a pattern is the
find history: ten entries, most-recent-first, evicted by whatever you last
typed. The proposal is a **library**: patterns you keep, each with a name that
says what it is for, editable in a form, and reachable from the Find bar as
easily as the history is.

This document is what the idea looks like after taking it apart: which part of
it carries the value, the three questions that decide the rest, what it costs
against what is already built, and the slice worth building first.

The verdict up front: the idea is sound and small. The valuable half is the
**name**, not the storage — and the one decision that shapes everything else is
where the library appears in the Find bar, because that decides whether it is
used at all.

## What the idea buys

1. **A pattern survives.** The history is a cache with a hard cap of ten
   (`FindHistoryStore.limit`), keyed by (pattern, encoding), and one afternoon
   of typing offsets and one-off strings evicts everything worth keeping. A
   library entry is not evicted by use of the app; it is removed when the user
   removes it.
2. **A pattern says what it is for.** `5A A5 F0 0F` is not self-describing, and
   neither is `$MODULE$`. The history can only show the pattern and its
   encoding, because that is all it knows. A library entry carries a name —
   *Aptio capsule header*, *ME FPT*, *Vendor S/N table* — which is what makes a
   list of twenty of them readable at a glance, and what makes a *shared* list
   possible at all (see "Beyond one bench").
3. **It carries the encoding with it, which is now load-bearing.** Since Smart
   Search, an encoding named by the user is where the hunt starts and it
   outranks the search already running (§11). A library entry is exactly such a
   statement — "this one is UTF-16 LE" — recorded once by whoever added it
   rather than re-guessed on every search.

## The three questions

### 1. Where does it appear in the Find bar?

This decides adoption. A library that takes three clicks to reach loses to
typing the pattern again.

**Option A — one dropdown, two sections.** The pattern combo's list grows a
library block above the history block, with a separator between them.

- *For*: nothing new to learn, nothing new to click, one place for "a pattern I
  have used before".
- *Against*: `NSComboBox` has no notion of a section. Its list is a flat array
  of object values; a header row is a selectable item that has to be caught and
  ignored, and the ignoring has already bitten once — the combo posts
  `selectionDidChangeNotification` in the middle of its own selection handling,
  which is why `patternSelectionChanged` defers to the next runloop turn. Two
  kinds of row in one list also means one label format has to serve both, and a
  library entry's name plus its pattern plus its encoding does not fit the
  `pattern — Encoding (CS)` shape the history uses.
- *Against, bigger*: the list is the **history's** interaction. Picking from it
  fills the field and sets the encoding; a library pick would do the same, and
  then the two are indistinguishable in use while differing in lifetime. When
  something is evicted, the user cannot tell whether it was theirs to keep.

**Option B — a menu button beside the field.** A small glyph (`bookmark`,
`text.book.closed`, or `list.bullet`) opening an `NSMenu` of the library, with
**Add to Library…** and **Manage Library…** at the bottom.

- *For*: a menu is the platform's own vocabulary for a named list — separators,
  disabled section titles, submenus for groups if groups ever arrive, and a
  keyboard walk that reads names rather than patterns. It costs one control's
  width on a bar that just got 44 points back from the encoding popup's names.
- *For*: it leaves the combo to be the history, and the two lists stay
  distinguishable in the only way that matters — where you got it from.
- *Against*: one more thing on the bar, and one more thing to discover.

**Option C — the library *is* the history's list, sorted.** Named entries pin
to the top and are never evicted; unnamed ones age out. One list, one store,
"keep this one" is a rename.

- *For*: the smallest model. No second store, no second control, and "promote
  what I just searched" is one gesture.
- *Against*: it conflates a cache with a document. The history is written on
  every search (§11) and read on every open; a library wants to be exported,
  imported, and edited in a form. Those pull in opposite directions, and the
  cap has to become "ten *unnamed*", which is a rule the user has to hold in
  their head.

**Option D — one field, and the list is a *menu*.** Option A's shape without
`NSComboBox`: replace the pattern field with an `NSSearchField` and hang the
list off its `searchMenuTemplate`. That is the control Xcode's find field is —
the magnifier grows a disclosure arrow, and what drops down is a real menu with
real sections: **Favorites**, then **Recent Queries**, then **Clear Recents**.

Verified against AppKit rather than assumed:

- `NSSearchField.searchMenuTemplate` takes an `NSMenu`. AppKit will splice its
  own recents into items tagged `recentsTitleMenuItemTag` (1000),
  `recentsMenuItemTag` (1001), `clearRecentsMenuItemTag` (1002) and
  `noRecentsMenuItemTag` (1003) — but those recents are plain strings, and ours
  carry an encoding and a case flag, so the app keeps building the recent items
  itself out of `FindHistoryStore` and skips the splicing. The tags are worth
  knowing about and not worth using here.
- `NSMenuItem.sectionHeader(title:)` (macOS 14, which is the floor) gives a real
  header rather than a disabled row pretending to be one.
- `NSSearchField` is an `NSTextField` subclass, so `controlTextDidChange`, the
  Return action, the focus handling and the count's layout all stay as they are.

What it buys beyond the sections:

- **The affordance is already on the bar.** The menu opens from the magnifier
  inside the field, so the library needs no control of its own — which is the
  "the bar is getting crowded" problem, answered by not adding anything.
- **It deletes the worst code in the bar.** A menu item has a target and an
  action; there is no selected index, nothing to deselect, and no
  `selectionDidChangeNotification` arriving in the middle of the combo's own
  selection handling — the reason `patternSelectionChanged` has to defer to the
  next runloop turn today, with a comment explaining that touching the
  selection there corrupts in-flight state. That whole path goes.
- The field's clear (⊗) button comes free, and one label format no longer has
  to serve both lists: a favourite shows its **name**, a recent shows
  `pattern — Encoding (CS)`.

What it costs: swapping the control (the bar builds it in one place), rebuilding
the template when either list changes (cheap, and the same trigger the combo's
`refreshHistoryItems` already has), and losing the combo's inline list
completion — which is already off (`completes = false`).

**Recommendation: D.** The instinct behind A was right and the control was the
problem: sections are exactly how this should read, and a menu is what can draw
them. B stays the fallback if the search field turns out to fight the bar's
layout, and C remains the wrong shape for the reason given.

### 1a. The menu, as settled at the prototype

`Design/pattern-field-prototype.swift` builds the bar twice — today's combo
above, the search field below — and the shape below is what came out of looking
at it. Recents first, because that is the list reached most often; each
section's commands under that section, fenced off by separators; and the two
lists in one row format, so the eye reads them the same way.

```
🕐 Recent Queries                                    ← header, `clock`
   "DE AD BE EF"  Hex bytes
   "windows"  UTF-16 LE, ignore case
   "Root"  ASCII, match case
   ─────────────────
   Add to Favorites
   Clear Recents
   ─────────────────
★ Favorites                                          ← header, `star.fill`
   ME FPT: "$FPT"  Hex bytes
   Vendor S/N table: "SN:"  ASCII, match case
   Windows loader string: "windows"  UTF-16 LE, ignore case
   ─────────────────
   Manage Favorites…
```

- **A row is `Name: "pattern"  flags`**, and a recent is the same row without
  the name — nothing typed into the field has one. The pattern is quoted so it
  cannot be confused with the name or the flags, and it is *not* monospaced:
  tried, and it read as code in a list of prose.
- **The flags are grey and a size smaller.** They say how the pattern is
  searched, not what is searched for, and colour is what separates the two at a
  glance. Both go after the pattern with no comma before them; a comma there
  read as another separator competing with the colour.
- **The case rule is stated either way** — `ignore case` as well as `match
  case`. It is a fact about the search, not the absence of one, and a reader
  should not have to know which way the silence went. **Hex says neither**:
  bytes have no case, the toggle is off the bar there (§11), and "ignore case"
  beside `41` would claim it matches `61`.
- **Type sizes**: rows and commands at 12pt against the system menu's 13 —
  these are a list to scan rather than commands to read one at a time — flags
  and headers at 11.

Two facts the prototype settled, both of which shape the code:

- **`NSMenuItem.sectionHeader(title:)` takes only a title**, so a header with an
  icon is built by hand: a disabled item with the symbol as its `image` and the
  title in 11pt semibold secondary. It reads as a header.
- **An item with no action is drawn grey.** `NSMenu.autoenablesItems` disables
  anything without a target and an action, which is why the first prototype
  came out uniformly dim — worth knowing before concluding anything about
  colours from a mock.

### 2. Does an activated library pattern enter the history?

The open question as posed. **No** — and the reason is stronger than "it would
be redundant":

- The history's cap is a scarce resource, and its job is "what I typed
  recently". A library pattern entering it evicts a typed entry to make room
  for something that is already kept elsewhere — which is the very problem the
  library exists to solve.
- With B, the two lists are reached from two controls, so nothing is lost by
  keeping them apart: what you typed is under the field, what you keep is under
  the glyph.
- So the rule reads: **the history records what was typed into the field.** A
  library pick fills the field, sets the encoding and searches; it records
  nothing. If the user then edits the text and searches, that is typing, and it
  records normally.

One consequence to be deliberate about: `FindBarView.adopt(encoding:)` records
the search when Smart Search settles on an encoding (§11). For a library pick
that must not record either — and it must not *rewrite the library entry's*
encoding, however tempting. An entry is the user's statement, not a cache of the
last thing that worked; a search that finds the pattern in another encoding is
news about the *file*, not about the entry.

### 3. What is an entry, and how much structure does it get?

The minimum that is still useful:

A favourite is a **recent with a name** — the same three fields the history
already keeps, plus the one thing a typed search has not got:

```swift
struct SearchPatternEntry {
    var name: String          // "ME FPT", the thing the menu shows
    var pattern: String       // the text as typed, not bytes
    var encoding: SearchEncoding
    var caseSensitive: Bool   // meaningless for hex, as everywhere (§11)
}
```

which is `FindHistoryStore.Entry` with a `name`. That is worth more than the
tidiness of it: one row renderer for both lists, one pick handler, one
validation — and "keep this one" is naming a recent.

Deliberately **not** in the first slice:

- **Groups or folders.** A submenu per group is easy to draw and hard to decide:
  by vendor? by region? by what the pattern is for? Twenty flat entries with
  good names are readable; the day someone has eighty, groups can be a name
  prefix (`ME / FPT`) before they are a data structure.
- **Bytes instead of text.** Storing the *text* keeps an entry editable in the
  form, re-parseable by `SearchEngine.parsePattern`, and honest about what the
  user wrote. Storing bytes would make `DE AD` and `DEAD` the same entry, which
  is right for the search and wrong for the list.
- **A note or description.** The row has no room for one, so it would live in
  a tooltip and the form; the name is what a pattern is called, and if a name
  cannot say what a pattern is for, a longer name can.
- **Regex or wildcards.** A separate feature with its own engine work; a
  library of exact patterns does not need it and is not blocked by it.
- **Per-file libraries.** A pattern is knowledge about a *class* of dumps, not
  about the file open in front of you. App-wide.

## What it costs, against what is already there

Almost everything this needs exists:

| piece | what it can reuse |
|---|---|
| the store | `FindHistoryStore`'s shape — a `UserDefaults` array of dictionaries, one swappable `defaults` for tests. No eviction, no cap, and a `name` field. |
| the editing form | `FileTypesSettingsViewController`: a table with add/remove buttons, inline editing, and a settings tab already built around exactly this shape. |
| validation | `SearchEngine.parsePattern(_:encoding:)` — the same call the bar makes, so an entry that cannot be searched cannot be saved, and the message is the one the bar already shows. |
| the search itself | nothing new. A pick fills the field, names the encoding, and presses Find — the `Request.smart(text:caseSensitive:preferring:)` path already carries "the user named this encoding" (§11). |
| the menu | `makePaneMenu` / `makeOffsetMenu` are the precedent for building an `NSMenu` from a model. |

So the work is: a store (~80 lines), a settings tab (~200, mostly table
plumbing, and the File Types tab is the template), a menu button on the bar
(~60), one rule about history (three lines), and the tests that pin the rules
above. No engine work, no storage-layer work, nothing on the hot path.

## Keeping the pattern you just typed

The requirement that decides whether a library ever fills up. Nobody opens
Settings to type a pattern from memory; they keep the one that just worked. So
the primary way an entry is created is **from the field**:

- **Add to Library…** takes the field's text, the encoding and the case flag as
  they stand, and asks for a name — a small sheet with the name field focused
  and empty, the pattern shown beneath it but not editable there (it is already
  what the user typed; editing belongs in the form).
- The encoding it saves is the one that **worked**, not the one that was
  chosen: after a Smart Search adopts an encoding the popup names it (§11), and
  reading the popup is therefore reading the answer. Saving right after a
  successful search is the good case, and it captures the pairing the entry
  exists to carry.
- Validation is the bar's own: a pattern that cannot be parsed cannot be saved,
  reported the way the bar reports it (`Invalid pattern`, §11).
- A pattern already in the library under the same encoding is not added twice —
  the command then offers to rename the existing entry, which is the only thing
  the user can have meant.
- Empty field, no command: it is disabled, like the stepper is at zero matches.

Where the command lives follows the answer to question 1: an item under the
field's own menu, below the two lists (**Add to Library…**, **Manage
Library…**), which is where Xcode puts **Insert Pattern** and **Clear
Recents** — the same place, for the same reason.

## Where the library is edited

**A Settings tab**, beside File Types. It is app-wide state the user curates,
which is what that window is for, and it inherits the window, the tab bar and
the table idiom for free. **Add to Library…** in the bar's menu opens a small
sheet with the name pre-filled empty and the pattern + encoding taken from the
field — because that is how a library actually gets built: not by opening
Settings and typing a pattern from memory, but by keeping the one you just used.

The alternative — a dedicated window — buys nothing here. Nothing about a
pattern list needs to sit beside a dump while you work.

## Beyond one bench (later, if ever)

Two things follow naturally once entries have names, and neither should hold up
the first slice:

- **Export and import.** A bench's pattern set is worth sharing, and a JSON file
  through a save/open panel is the whole of it (the app is sandboxed; a
  user-chosen location is a panel away). This is also the honest backup story
  for `UserDefaults`.
- **A seeded set.** Tempting and best refused, at least at first: which patterns
  are "standard" depends on the boards you see, and the app's stance elsewhere
  is that lists are ticked by the user and not by the app (File Types, §D). A
  library that ships with someone else's twenty entries is a list to prune
  before it is a list to use.

## The slice worth building first

1. The store: a history entry plus a name, no cap, order as held.
2. The Settings tab: add, remove, edit, validate, and reorder by dragging.
3. The field's menu: **Favorites** (the library, by name), **Recent Queries**
   (the history, as now), then **Add to Library…**, **Manage Library…** and
   **Clear Recents**. Picking an entry fills the field, names the encoding, and
   searches.
4. **Add to Library…** from the field, with the encoding that worked — without
   this the library starts empty and stays empty.
5. The history rule: a pick records nothing; only typing records.

That is a complete feature — a pattern can be kept, named, found and used —
and everything deferred above (groups, export, seeding, regex) can be added
later without changing what this slice does.

## Decisions taken

**Settled at the prototype** (`Design/pattern-field-prototype.swift`): the
search field sits in the bar's stack exactly as the combo does — same height,
same baseline, same stretch, the count's fixed width undisturbed — and the
magnifier's disclosure arrow is the affordance, so nothing is added to the bar.
The field's clear (⊗) comes with it.

**Settled by decision:**

1. **A pick fills the field and runs the search**, from either list. This is a
   change to what the history does today, where a pick fills and stops and the
   user presses Return — and the change is the right way round: a list entry is
   chosen deliberately, and the press that follows it never means anything else.
2. **Escape belongs to the field, and the bar is closed by `Done`.** The first
   Escape closes the menu; the second clears the field.
   *This one costs something and is worth writing down:* §11 currently has
   Escape closing the bar, which is what Escape does in every other find bar on
   the platform (Safari, TextEdit, Xcode), and what the existing tests assert.
   Trading it for "clear the field" buys the field's own idiom and the ⊗'s
   keyboard equivalent, and the exits become `Done` and the ⊗. §11 and
   `hideFindBar`'s Escape path change with it, and so does the rule that the
   highlighting ends "by `Done` or Escape".
3. **A pick sets three things**: the pattern, the encoding, and the case flag —
   an entry records `match case` or `ignore case`, and the `Aa` toggle follows
   it or the row is lying. The encoding also becomes Smart Search's stated
   preference (`preferring:`, §11), which makes it the first attempt.
4. **The menu shows everything there is**, as far as the screen allows;
   `NSMenu` scrolls past that. If a real library outgrows it, that is the point
   at which to decide between a cap and groups — not before.
5. **Natural order, and the user's.** Favourites appear in the order the list
   holds them, and the list is reordered by dragging rows in the form. No
   sorting rule to remember, and the order a bench keeps them in is knowledge
   too.
6. **Recents stay unique**, and a repeat moves its entry to the top — which is
   what `FindHistoryStore.record` already does, keyed by (pattern, encoding).
7. **An entry cannot stop parsing**, because what it can hold is what the
   parser accepts and the parser is code, not data. If one ever does — a
   hand-edited plist, a format change — the text goes into the field as it
   stands and the bar reports the error the way it reports any other
   (`Invalid pattern`, §11), which needs no new UI.
8. **No note field. A favourite is a recent with a name** — the same pattern,
   encoding and case flag, plus the one thing a typed search has not got. That
   is worth more than the tidiness: one row renderer, one pick handler, one
   validation, and a favourite can be built from a recent by naming it.

Nothing above is open. What is left is the building, in the order the slice
above gives: the store (a history entry plus a name), the form (a table with
drag reordering, add, remove, validate), the field and its menu, and the four
rules — a pick fills and searches, a pick sets three things, the history
records only what was typed, and Escape belongs to the field.
