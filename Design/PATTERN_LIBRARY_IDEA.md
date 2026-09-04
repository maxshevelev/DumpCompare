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

**Recommendation: B**, with the combo's list left exactly as it is. The user's
own instinct was A, and it is the cheaper-looking option, but the cost lands in
the wrong place: `NSComboBox`'s flat list is the weakest surface in the bar
already, and the feature's whole value is that a library entry is *not* a
recent search. A menu says that by existing.

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

```swift
struct SearchPatternEntry {
    var name: String          // "ME FPT", the thing the menu shows
    var pattern: String       // the text as typed, not bytes
    var encoding: SearchEncoding
    var caseSensitive: Bool   // meaningless for hex, as everywhere (§11)
    var note: String          // optional, one line, for the tooltip
}
```

Deliberately **not** in the first slice:

- **Groups or folders.** A submenu per group is easy to draw and hard to decide:
  by vendor? by region? by what the pattern is for? Twenty flat entries with
  good names are readable; the day someone has eighty, groups can be a name
  prefix (`ME / FPT`) before they are a data structure.
- **Bytes instead of text.** Storing the *text* keeps an entry editable in the
  form, re-parseable by `SearchEngine.parsePattern`, and honest about what the
  user wrote. Storing bytes would make `DE AD` and `DEAD` the same entry, which
  is right for the search and wrong for the list.
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

Where the command lives is the one open detail, and it follows the answer to
question 1: an item at the bottom of the library menu is the natural home
(**Add to Library…**, **Manage Library…**), and if the bar turns out too
crowded for a second glyph the same command belongs in the pattern field's
contextual menu, where "do something with what I typed" already reads.

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

1. The store, with a name, and no cap.
2. The Settings tab: add, remove, edit, validate.
3. The bar's menu button: the entries, then **Add to Library…** and **Manage
   Library…**. Picking one fills the field, names the encoding, and searches.
4. **Add to Library…** from the field, with the encoding that worked — without
   this the library starts empty and stays empty.
5. The history rule: a pick records nothing; only typing records.

That is a complete feature — a pattern can be kept, named, found and used —
and everything deferred above (groups, export, seeding, regex) can be added
later without changing what this slice does.

## What would need deciding before writing any of it

- The glyph, and whether the bar has room for it beside `Find`, the field, the
  encoding popup, the wand, `Aa`, the count, ‹ ›, results and Done. It is
  getting crowded; if something has to give, the honest candidate is moving
  **Add to Library…** into the pattern field's contextual menu.
- Whether an entry's name must be unique. Two entries called *FPT* differing
  only in encoding are legitimate; two identical ones are a mistake the form
  should probably prevent, and probably by merging rather than refusing.
- What a pick does when the pattern cannot be parsed *now* — an entry saved
  under an encoding whose parser has since changed, or hand-edited defaults.
  The bar's `Invalid pattern` (§11) covers it, but the entry should say so in
  the list rather than only when used.
