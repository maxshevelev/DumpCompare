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

Important rules:
- Domain code must be pure Swift, modular, and unit-testable.
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

