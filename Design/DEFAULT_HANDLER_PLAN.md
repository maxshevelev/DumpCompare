# Default-handler Settings tab — state & decision log

Status: **BLOCKED on a sandbox decision.** Session paused 2026-08-28; resume here.

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

## The decisive finding — the sandbox blocks the write

The probe **failed** and the cause is isolated:

| context | call | result |
|---|---|---|
| inside the app sandbox (hosted test) | `LSSetDefaultRoleHandlerForContentType("bin", .viewer, dev.maxik.DumpCompare)` | **-54 (`permErr`)** |
| unsandboxed CLI (`swift /Users/maxik/.claude/jobs/654a7325/tmp/ls-probe.swift`) | same call, same bundle id | **0 (`noErr`)** — took `.bin`, then restored it |

`-54` is a generic permission error, consistent with the sandbox refusing the
write to the per-user Launch Services database
(`~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`),
which lies outside the app's container. There is no entitlement or sanctioned
API that lets a sandboxed app write it. The unsandboxed CLI probe proves the API
itself is fine; the sandbox is the blocker. The probe left the machine as found
(`.bin` → `com.apple.archiveutility`, restored).

Probe build/test log: `/Users/maxik/.claude/jobs/654a7325/tmp/probe.log`
(test fails on the sandboxed probe by design).

## Decision needed (user, next session)

Two viable ways forward — the user's call, they were about to choose when the
session paused:

**Option A — drop the app sandbox** (one line in `project.yml`: remove
`com.apple.security.app-sandbox`).
- Simplest. No new code.
- Costs:
  1. The app loses its file-access restriction (it could read/write anything it
     can reach — fine for a personal dev tool, but a real security-model change).
  2. **Settings reset once**: sandboxed `UserDefaults.standard` lives in
     `~/Library/Containers/dev.maxik.DumpCompare/Data/Library/Preferences/…`,
     unsandboxed it reads `~/Library/Preferences/dev.maxik.DumpCompare.plist`.
     Old keys (Appearance, WordSize, AppTheme, EditingSettings, FindHistory,
     LayoutSettings, FilePaneView height, bookmarks) become invisible → app
     starts at defaults once.
  3. **Bookmark-based reopen breaks**: the app-scope security-scoped bookmarks
     stop resolving; the last-open files must be re-added by hand.
- The `com.apple.security.files.user-selected.read-write` and
  `com.apple.security.files.bookmarks.app-scope` entitlements can then also be
  dropped, and the `application(_:open:)` pipeline keeps working (a file
  launched by Finder still arrives via Launch Services).

**Option B — keep the sandbox, add a tiny unsandboxed helper.**
- Add a second target `DefaultHandlerHelper` (`type: tool`, no entitlements,
  ad-hoc signed, like the app) that reads (extension, bundle id) from argv and
  performs the LS write; embed it in the app bundle; the sandboxed app invokes
  it via `NSTask` and reads its exit code. A sandboxed app may spawn an
  unsandboxed child process — the child runs under its own code signature.
- This is the standard macOS pattern for "sandboxed app + system-wide change".
- Keeps every existing feature (settings, bookmarks, file-access restriction).
- Costs: a second target, an XcodeGen copy/embed step (verify `embed: true`
  works for a `tool` product, else a post-build script that `cp`s it into
  `Contents/MacOS`), an NSTask bridge, and re-aiming the probe test at the
  helper's exit code.
- The File Types tab's service calls become closures that spawn the helper, so
  VC tests still stub them.

(There is no third way: every default-handler API — classic LS, `NSWorkspace`
on macOS 15+ — writes the same per-user database the sandbox blocks, and the
user explicitly asked for in-app registration, so "informational tab" is out.)

## Not yet done (all pending — the plan's Steps 2–5 and tests)

- `DumpCompareApp/DefaultHandlerSettings.swift` — model, mirroring
  `FindHistoryStore` (SheetControllers.swift:566): static enum, swappable
  `defaults`, `[[String: Any]]` under `"DefaultHandlerFileTypes"`;
  `Entry { ext, enabled, previousHandler }`; defaults `[("bin", true), ("rom", true)]`;
  `entries`/`add`/`remove`/`toggle`/`resetToDefaults`/`applyEnabledDefaults`;
  normalization (trim, strip leading dot, lowercase, dedup, reject non-alphanumeric).
- `AppDelegate` — call `DefaultHandlerSettings.applyEnabledDefaults()` in
  `applicationDidFinishLaunching` (re-assert the checked list each launch).
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

- `DumpCompareApp/DefaultHandlerService.swift` (new)
- `DumpCompareTests/DefaultHandlerSandboxProbeTests.swift` (new)
- `DumpCompare.xcodeproj` (regenerated by xcodegen)
