# Default-handler Settings tab — state & decision log

Status: **DONE.** Built 2026-08-28, sandboxed, on `NSWorkspace`. The feature and
every measurement behind it are documented in `Design/REQUIREMENTS.md` §25, which
is the reference from here on; this file is kept as the decision log that got
there.

## Feature

A new tab in Settings — **File Types** — that registers DumpCompare as the
**default** viewer (double-click opens DumpCompare) for a user-managed list of
file extensions:

- Default list: `.bin`, `.rom` (pre-checked).
- Per-type checkbox: on → set DumpCompare as the default handler; off → restore
  the previous handler.
- `+`/`−` footer buttons (the SegmentsForm idiom) to add/remove types.
- Adding a type prompts for an extension (NSAlert + text field); the list is
  persisted in UserDefaults and re-applied at launch.

The approved plan is at
`/Users/maxik/.claude/plans/cheerful-petting-pebble.md` (the plan-mode file).

## What is already done

1. **`DumpCompareApp/DefaultHandlerService.swift`** (NEW, committed nothing yet)
   — thin Launch Services wrapper: `currentHandler(for:)`,
   `setSelfAsDefault(for:)`, `restoreDefault(for:to:)` over
   `LSCopyDefaultRoleHandlerForContentType` / `LSSetDefaultRoleHandlerForContentType`,
   type resolved via `UTType(filenameExtension:)`, role `.viewer`.
2. **`DumpCompareTests/DefaultHandlerSandboxProbeTests.swift`** (NEW) — hosted
   test (runs inside the sandboxed app via TEST_HOST) that sets `.bin`'s default,
   asserts noErr, restores.
3. `xcodegen generate` ran; project builds.

## What the probes actually establish

All rows below are measured on this machine (macOS 26), the sandboxed ones from a
hosted test inside the app — the same sandbox the app itself runs in (proved
independently: the host's `temporaryDirectory` is redirected into the container
and a write to `/private/tmp` is refused).

| context | call | result |
|---|---|---|
| sandboxed app | `LSSetDefaultRoleHandlerForContentType` (deprecated in 12) | **-54 `permErr`** |
| sandboxed app | `NSWorkspace.setDefaultApplication(at: ownBundle, toOpen: UTType("bin"))` | **succeeded, silently** — the handler for `.bin` actually changed |
| sandboxed app | reading the current handler (`LSCopyDefaultRoleHandlerForContentType`, `NSWorkspace.urlForApplication(toOpen:)`) | works |
| sandboxed app | `setDefaultApplication` pointing at **another** app (the restore) | macOS asks the user; unanswered in a headless run it returns `userCanceledErr` (-128) |
| unsandboxed CLI | `LSSetDefaultRoleHandlerForContentType` pointing at another app | returns `noErr`, but macOS still asks the user, and the user's answer is what lands |

Three conclusions, and they replace the previous diagnosis:

1. **The sandbox does not block the feature.** What is blocked is the API the
   service was built on — deprecated since macOS 12. `NSWorkspace`'s replacement
   (macOS 12+, so available at the 14.0 target) writes the same binding from
   inside the sandbox with no entitlement and no helper. **Option A (drop the
   sandbox) and Option B (unsandboxed helper) are both off the table** — nothing
   to decide, and neither cost has to be paid.
2. **Claiming a type for yourself is silent; handing one to another app needs the
   user's consent.** So "uncheck → restore the previous handler" cannot be
   silent, and the user can decline it. The tab must therefore never trust its
   own checkbox: after every attempt it re-reads the real handler (which the
   sandbox permits) and shows that.
3. **Not every extension needs a write at all.** `.bin` resolves to
   `com.apple.macbinary-archive` — a real system type whose default is Archive
   Utility, so "make `.bin` ours" means taking MacBinary away from it. `.rom`
   resolves to a dynamic `dyn.…` type that nobody else claims, and DumpCompare
   already opens it on a double-click from the Info.plist declaration alone. The
   checkbox for an uncontested extension has nothing to do; naming the current
   handler is the useful thing on screen.

## Design decisions this changes

- **The service moves to `NSWorkspace`**: `setDefaultApplication(at:toOpen:completionHandler:)`
  plus `urlForApplication(toOpen:)` for the read. It is asynchronous and can come
  back with an error the user caused (declined the consent alert), which is a
  normal outcome, not a failure to report as one.
- **Nothing is applied at launch.** The plan had the checked list re-asserted
  every launch. Now that claiming is silent, that would silently take a type back
  from the user each time they handed it elsewhere in Finder. Assert only on the
  user's click; at launch merely read, so the checkboxes reflect the system.
- **Nothing is pre-applied.** Ship `.bin` and `.rom` in the list *unchecked*:
  the first launch must not quietly take MacBinary from Archive Utility.
- The sandbox probe test is no longer a gate. Re-aim it at the `NSWorkspace`
  path, or drop it — but note it changes real system state, so a test that takes
  a type must hand it back, and handing back needs a human at the alert. That
  makes it a poor automated test: prefer testing the model and the view
  controller against stubbed service closures, and leave the real write to
  manual verification.

## Not yet done (all pending — the plan's Steps 2–5 and tests)

- `DumpCompareApp/DefaultHandlerSettings.swift` — model, mirroring
  `FindHistoryStore` (SheetControllers.swift:566): static enum, swappable
  `defaults`, `[[String: Any]]` under `"DefaultHandlerFileTypes"`;
  `Entry { ext, enabled, previousHandler }`; defaults `[("bin", true), ("rom", true)]`;
  `entries`/`add`/`remove`/`toggle`/`resetToDefaults`/`applyEnabledDefaults`;
  normalization (trim, strip leading dot, lowercase, dedup, reject non-alphanumeric).
- `AppDelegate` — nothing. (The plan's launch-time `applyEnabledDefaults()` is
  dropped; see "Design decisions this changes".)
- `DumpCompareApp/FileTypesSettingsViewController.swift` — table (checkbox +
  extension columns), `+`/`−` footer copied from `SegmentsForm.makeFooter()`
  (SegmentsForm.swift:242), add via NSAlert + text field behind a replaceable
  `promptForExtension` closure, service calls behind replaceable closures,
  `−` disabled with no selection. Follow `EditingSettingsViewController` layout
  (root width 480, top-down pins).
- `SettingsWindowController` — wire the sixth tab ("File Types", SF Symbol,
  toolbar case + @objc handler → `selectTab`), exactly like the existing five.
- Tests: `DefaultHandlerSettingsTests` (pure, `UserDefaults(suiteName:)`),
  `FileTypesSettingsViewControllerTests` (hosted, real window, stubbed prompt +
  service).
- `Design/REQUIREMENTS.md` — document the tab (§22).
- Build + full suite into the dedicated DerivedData
  (`/Users/maxik/.claude/derived-data/dumpcompare`).
- **No commit/push until the user says "push".**

## Files touched so far (uncommitted)

- `DumpCompareApp/DefaultHandlerService.swift` (committed; **to be rewritten on
  `NSWorkspace`** — its Launch Services write is the call the sandbox refuses)
- `DumpCompareTests/DefaultHandlerSandboxProbeTests.swift` — deleted: its premise
  (the sandbox blocks the write) is false for the API the app now uses, and the
  real write cannot be automated cleanly, since handing a type back needs a human
  at the system's confirmation. The measurements it stood for are in §25.1.
