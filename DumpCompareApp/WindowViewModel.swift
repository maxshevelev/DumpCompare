import Foundation

/// Hosts the up to two file panes and the active-pane pointer (§3).
///
/// Milestone 4 uses only `pane1` (single-file mode); comparison mode (M5)
/// activates `pane2` and the splitter. Keeping the pane state here keeps the
/// view controller free of document logic.
@MainActor
final class WindowViewModel {
    let pane1 = PaneViewModel()
    let pane2 = PaneViewModel()

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
}
