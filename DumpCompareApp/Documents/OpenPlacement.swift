import Foundation

/// Pure placement decision for the File > Open panel (§4.1) — no AppKit, so it
/// is unit-testable. Drag-and-drop uses its own targeted rules (§4.3).
enum OpenPlacement {
    struct Result: Equatable {
        /// Pane the first selected file opens into (0 or 1), if any.
        var firstFilePane: Int?
        /// Whether the second selected file also opens (only when both panes
        /// were empty; otherwise it would clobber an occupied pane).
        var openSecond = false
        /// Number of additional selected files that are ignored (need a
        /// notification), given `fileCount`.
        var ignoredCount = 0
    }

    /// Rules §4.1.1–§4.1.3:
    /// - no panes occupied → first two files to panes 1/2, extras ignored;
    /// - only pane 1 occupied → first file to pane 2, all others ignored;
    /// - both occupied → first file replaces the active pane, all others ignored.
    static func plan(
        activePaneIndex: Int,
        pane1Open: Bool,
        pane2Open: Bool,
        fileCount: Int
    ) -> Result {
        switch (pane1Open, pane2Open) {
        case (false, _):
            return Result(firstFilePane: fileCount >= 1 ? 0 : nil,
                          openSecond: fileCount >= 2,
                          ignoredCount: max(0, fileCount - 2))
        case (true, false):
            return Result(firstFilePane: fileCount >= 1 ? 1 : nil,
                          openSecond: false,
                          ignoredCount: max(0, fileCount - 1))
        case (true, true):
            return Result(firstFilePane: fileCount >= 1 ? activePaneIndex : nil,
                          openSecond: false,
                          ignoredCount: max(0, fileCount - 1))
        }
    }
}
