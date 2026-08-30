# Tabs — several comparisons in one window

> A tab holds what the window holds today: two panes, a minimap, one bookmark
> list, one comparison. Nothing inside a tab is new. What is new is that there
> can be more than one of them, and that everything the app currently calls
> "the window's" has to be sorted into *the tab's* and *the application's*.

## Why

A bench session is rarely one comparison. The dump comes off the chip, gets
compared against the donor, and then something else needs looking at — the
second chip of the pair, the image as it was before the patch, a third board's
read for a tiebreak. Today each of those means closing what is open, because
there is one window and two panes in it.

The pane count is not the problem. Comparison is by absolute offset between
exactly two files and that is deliberate (§1); a third pane would not make the
comparison richer, it would make it ambiguous. What is missing is a second
*comparison*, kept beside the first, with its own two panes and its own
bookmarks.

## What it adds

- **⌘T** opens a new tab, empty. The window already opens empty and one pane
  wide (§3.1); a new tab continues that rule rather than inventing another.
- **A pane can be torn off into its own tab** from the pane header's menu,
  taking its document with it.
- Everything a comparison consists of becomes per tab: the two panes, the
  active-pane pointer, the mode, the minimap's state, the comparison index, and
  the bookmark list.

## Native tabs, not a tab bar of our own

Each tab is a real `NSWindow` joined with `addTabbedWindow(_:ordered:)`, with
`NSWindow.allowsAutomaticWindowTabbing` on and one `tabbingIdentifier` shared by
every window the app makes.

What that buys, none of which then has to be built or maintained: the tab bar
itself, ⌃Tab and ⌘1…⌘9, dragging a tab out into its own window and dragging one
back in, and the Window menu's Show Tab Bar / Show All Tabs / Move Tab to New
Window / Merge All Windows.

**New Tab is not among them.** `newWindowForTab(_:)` is what the tab bar's +
button calls, and AppKit looks for it along the *window's* responder chain — the
app delegate is past the end of that. The ⌘T command in the File menu is the
app's own to add, the way Terminal and Safari add theirs. The comment in
`AppDelegate` that today calls those items "dead UI" and switches tabbing off is
about to become wrong in the other direction.

The cost is honest: **a tab is a window**, so every multi-window defect the app
has been carrying becomes reachable by a user rather than only by the test
suite. That is not a reason to build a tab bar of our own — it is a reason to
fix the defects, which are listed below and are worth fixing regardless.

The alternative — one window, our own `NSView` tab bar, child view controllers —
keeps the menu bar addressed to a single controller and gives complete control
of the tab's appearance. It also means writing the bar, the reordering, the
drag-out, and the keyboard handling by hand, and ending up with something that
behaves not quite like every other macOS app. Rejected.

## What is the tab's, and what is the application's

| Per tab | Application-wide |
| --- | --- |
| both panes, the active-pane pointer, the mode | settings, theme, file-type registration |
| **the bookmark list** | the Settings window |
| the minimap's mode and its overview summaries | the menu bar |
| the comparison index, the search, the status bar | which files are open, and where (§4.1 rule 6) |
| the segment partitions (already per pane) | the sandbox's security-scoped bookmarks |

Bookmarks land on the tab's side without argument: they already live as long as
the window rather than as long as the file (§20), and a tab is exactly a
window's worth of work.

## The three things that are the window's today and should not be

All three are in `MainWindowController`, and all three are worth fixing whether
or not tabs are ever built.

1. **The menu bar is built per window.** `buildMainMenu()` runs in `init()` and
   assigns `NSApp.mainMenu` — but there is one menu bar per application, so with
   two windows the second one's menu replaces the first one's. Worse, the File
   submenu's helper sets `item.target = mainViewController` explicitly, so its
   commands are addressed to one particular window's controller rather than to
   whichever tab is in front. Edit and View already leave the target nil and
   travel the responder chain, which is what File has to do too.

2. **The Settings window is a window's property.** `settingsWindowController` is
   `lazy var` on `MainWindowController`, so N tabs would be N Settings windows.

3. **The frame autosave name is shared.** Every window calls
   `setFrameAutosaveName("MainWindow")`. Tabs make this mostly moot — tabs of one
   window share that window's frame, so there is nothing per-tab to save — but
   the name still has to belong to the host window alone rather than to every
   window that gets created.

The toolbar needs nothing: it is already per window and already carries a unique
identifier per window, which is the fix that stopped AppKit from replaying one
window's toolbar mutations into another's.

## Rule 6 becomes the application's

`openIntoPane` enforces §4.1 rule 6 — the same file cannot be open in both
panes — by comparing `FileIdentity` (device + inode, not the spelling of the
path) against the *other pane* of the same window. The rule is not fussiness:
two live documents over one file are two dirty states, two change watchers, and
a piece table whose base file moves under it when the other document saves.
That is the family of bug `StorageSaver` now refuses outright.

With tabs the question stops being a window's and becomes the application's, so
the check moves behind a small registry that knows every tab. Nothing is stored
in it: the answer is computed from the panes themselves at the moment it is
asked, so it cannot drift out of step with what is actually open — which the
two-pane check never could either.

Once the answer names a tab, the refusal can stop being a dead end. Today
opening an already-open file raises "File already open … cannot be opened
twice" and that is the end of it. The useful answer in a tabbed app is to
**switch to the tab that holds it** and activate the pane. The flat refusal
survives only inside one tab, where two panes on one file remain meaningless.

## Tearing a pane into its own tab

**Open in New Tab** in the pane header's menu *moves* the document rather than
opening the file again. Opening the URL a second time would violate rule 6 the
moment it succeeded; moving it keeps the file open exactly once, brings the
unsaved edits, the undo history, the segments and the watcher along, and never
re-reads the disk. The mental model is "split this comparison in two", which is
what the gesture is for.

The cleanest mechanism is to move the whole `PaneViewModel` into the new tab's
`pane1`: everything it owns travels by construction, so nothing has to be
enumerated and nothing can be forgotten. The one reference that must be
re-pointed is its `bookmarkStore`.

**The bookmarks are copied.** The marks were made against absolute offsets, and
those offsets mean the same thing in the torn-off file; losing them on a gesture
that means "let me look at this on its own" would be a poor trade. Both tabs
keep the full list, and from that moment the two lists are independent — a mark
added in one does not appear in the other.

Two traps, both easy to fall into:

- **Do not hand the new tab the existing store.** `WindowViewModel.bookmarkStore`
  is a `let` built in `init()` and wired to both panes there, so a new tab gets
  its own instance for free. Passing the reference instead would give neither a
  copy nor a move but a third thing: one list serving two tabs, where removing a
  mark in one silently removes it in the other.
- **The copy needs one notification, not N.** `BookmarkStore`'s verbs are all
  per row (`add`, `toggle`, `remove`) and each fires `onChange(row)`, which fans
  out to both panes and the controller. Replaying a list as N calls to `add`
  would repaint a tab that is still being built once per mark. It needs a
  seeding entry point — `init(bookmarks:)` or `seed(_:)` — that reports once.
  `Bookmark` is a value type, so the copy itself is a copy of the array.

## Keys

Three commands are competing for two familiar keys.

- **⌘T** — New Tab. Implementing `newWindowForTab(_:)` is enough; AppKit supplies
  the key equivalent and the menu item.
- **⌘N** stays **New File**, the empty in-memory document. On a bench a scratch
  document is wanted more often than a window, and there is nothing to be gained
  by re-teaching a key that already means the right thing.
- **⇧⌘N** — New Window, for two windows on two monitors.
- **⌘W** cascades: it closes the active **pane**; with no pane left it closes the
  **tab**; if that was the last tab it closes the **window**. This is today's
  rule (pane, then window) with one step inserted, so nothing has to be
  unlearned. **⇧⌘W** closes the window and every tab in it.

## The tab's name

The tab is named by its files: the file's name in single-file mode,
`A.bin ↔ B.bin` in comparison, `Empty` for a tab holding nothing. A tab bar with
nothing to read is not worth having, so this is not an optional refinement.

Not the app's name, which says nothing about one window in particular, and not
`Untitled`, which already means a New File that has never been saved — an empty
tab and a fresh document must not read alike.

The name is `window.title`, which is currently the constant `"DumpCompare"` with
`titleVisibility = .hidden` because the toolbar occupies the whole title bar.

## Two things to settle by experiment, not at the desk

1. **What a hidden title does to the tab's label**, given a toolbar that fills
   the title bar. The tab bar reads `window.title`, but how that interacts with
   `titleVisibility = .hidden` and a full-width toolbar is a question for a
   running window, not for a document. If they fight, it changes the toolbar's
   layout, not the model.

2. **What tabbing does to the test suite.** Twelve test classes build a
   `MainWindowController`, and it was exactly the accumulation of windows in one
   suite that used to raise `-[NSToolbar _itemAtIndex:]`. With automatic tabbing
   on, those windows will also start joining each other. `tabbingMode =
   .disallowed` on the test path is the likely answer, but it has to be
   confirmed by a run rather than assumed.

## Implementation plan

**1. Everything that is wrong about one window, fixed with one window.** The
menu bar and the Settings window move to `AppDelegate`; the File submenu's items
drop their explicit target and travel the responder chain; rule 6 moves behind
the registry. No tab exists yet and no behaviour changes — the suite staying
green is the whole acceptance test.

**2. A second window (⇧⌘N), still without tabs.** This is where the real
multi-window defects surface: menu routing, validation, the frame, the watchers,
the background tasks. Fixing them here is cheaper than fixing them behind a tab
bar.

**3. Tabs.** `allowsAutomaticWindowTabbing`, `tabbingIdentifier`,
`newWindowForTab(_:)`, the tab's name, and the "switch to the tab that holds it"
half of rule 6.

**4. Tearing a pane off**, the pane header's menu item, the bookmark copy and
its seeding entry point, and the ⌘W cascade.

Step 2 earns its place precisely because a tab *is* a window: if multi-window
works, tabs are nearly free; if it does not, tabs only hide the breakage behind
a nicer bar.

## Decisions taken

- Native `NSWindow` tabs, not a tab bar of our own.
- A tab owns both panes, the mode, the minimap's state, the comparison, and the
  bookmark list. Settings, the theme, the menu bar and the open-file registry
  are the application's.
- **Open in New Tab moves the document**, it does not open the file twice.
- **The bookmark list is copied** on the tear-off, and the two lists then diverge.
- ⌘T new tab, ⌘N still New File, ⇧⌘N new window, ⌘W cascades pane → tab → window.
- The tab is named by its files.
