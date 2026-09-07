SHORT PROJECT CONTEXT

Project: macOS GUI tool to visually compare and edit two binary files.

Stack:
- Xcode project written in Swift.
- macOS 14+.
- No third-party dependencies unless absolutely unavoidable.
- Swift Concurrency.
- UI on MainActor.
- Long-running operations in background.

Architecture:
- Storage layer.
- Domain/model layer.
- ViewModel/presentation state layer.
- View layer.

Packages:
- Every unit of code outside the app target is a local SPM package. There are no
  remote dependencies, and each package is listed in `packages:` in
  `project.yml` — including one only a tool-module links, so Xcode can see it.
- `Packages/<Name>` — a shared library: one target `<Name>`, one product
  `<Name>`, tests in `Tests/<Name>Tests`.
- `Modules/<Name>` — a tool-module: two targets, `<Name>` (pure, no AppKit) and
  `<Name>UI` (the view controller and the `ToolModule` conformance), and a
  product for each. The tests cover the pure target; the host is tried in the
  app suite. Also wire it into `DumpCompareApp/Tools/ToolRegistry.swift`.
- A target declares every product it imports. Linking something because the
  host app happens to link it too compiles until the app stops.
- A tool-module depends on `ToolModuleKit` and on shared packages. Never on
  `DumpCompareApp`, never on `DumpCompareCore`, never on another tool-module.
- Code two tool-modules both need moves to a shared package under `Packages/`.
- Every package: `swift-tools-version: 5.9`, `platforms: [.macOS(.v14)]`, and a
  header comment saying what it is and why it is a package of its own.
- After adding a package or a source file: `xcodegen generate`. The test script
  finds a new package by itself.

Running the tests:
- `Scripts/run-tests.sh` — every Swift package, then the app suite in groups,
  one group at a time. `-o <regex>` runs only the classes whose names match;
  `--no-packages` skips the packages.
- Never run two `xcodebuild test` invocations at once: they share one UI
  session, and the tests that wait on a window, an animation or a panel then
  fail for reasons that are not bugs.

Important rules:
- Domain code must be pure Swift, modular, and unit-testable.
- Every split view is `ALSplitView`. Never `NSSplitView`: it sizes its panes
  from their content, which fights the enclosing layout, and its divider
  position has to be set after the view has a size. `ALSplitView` places panes
  by explicit frame math and takes a policy per pane (`.fill`,
  `.proportional`, `.fixed`) that is right from the first layout pass.
- The app has two file slots: File A and File B.
- File B is optional.
- If only one file is open, the app is in single-file mode.
- Hex view shows 16 bytes per row plus ASCII representation.
- Comparison is by absolute zero-based offsets only.
- Do not implement block matching or diff alignment.
- Very large files must be supported via chunked storage, not full RAM loading.
- Internal byte ranges are half-open: [start, end).
- UI dialogs may use inclusive end, but must convert to half-open internally.
- Difference state uses background color.
- Modified unsaved state uses red foreground.
- If a byte is both different and modified, show both states.

