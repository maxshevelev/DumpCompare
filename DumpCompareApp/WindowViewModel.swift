import Foundation

/// Hosts the up to two file panes and the active-pane pointer (§3).
///
/// Milestone 4 uses only `pane1` (single-file mode); comparison mode (M5)
/// activates `pane2` and the splitter. Keeping the pane state here keeps the
/// view controller free of document logic.
@MainActor
final class WindowViewModel {
    var pane1 = PaneViewModel()
    var pane2 = PaneViewModel()

    private(set) var activePaneIndex = 0

    var activePane: PaneViewModel {
        activePaneIndex == 0 ? pane1 : pane2
    }

    var openPaneCount: Int {
        (pane1.isOpen ? 1 : 0) + (pane2.isOpen ? 1 : 0)
    }

    var hasOpenFile: Bool {
        pane1.isOpen || pane2.isOpen
    }

    func setActivePane(_ index: Int) {
        activePaneIndex = index
    }

    /// Swaps the two panes' documents (the "Swap Panels" command): pane 1 and
    /// pane 2 exchange contents. The active pane follows its document, so the
    /// pane the user was working on stays active after the swap. Non-destructive
    /// — pure reference swap, so no confirmation is needed.
    func swapPanes() {
        swap(&pane1, &pane2)
        activePaneIndex = activePaneIndex == 0 ? 1 : 0
    }

    /// Closes the pane at `index`, handling the §3.5 promotion rule: when pane 1
    /// is closed and pane 2 is open, pane 2 becomes pane 1. The caller is
    /// responsible for the dirty save/discard/cancel prompt before calling.
    /// After this, `apply(mode:)` re-renders the appropriate mode.
    func closePane(_ index: Int) {
        if index == 0 {
            if pane2.isOpen {
                // Promote pane 2 → pane 1, then close the old pane 1's document.
                let closed = pane1
                pane1 = pane2
                pane2 = closed
                pane2.close()
            } else {
                pane1.close()
            }
        } else {
            pane2.close()
        }
        activePaneIndex = 0
    }
}
