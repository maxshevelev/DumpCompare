import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §4/§5: a right-click on a pane's header (the strip with the document icon and
/// file name) pops a File menu that carries the same items as the app menu bar's
/// File submenu, plus the header-only Show in Finder and a separate Swap Panels
/// block. The context menu's File items target `mainViewController` and carry
/// the pane they were built for in `representedObject`, so New, Open, Save and
/// Close act on THAT pane — even when only one pane is open — never on the
/// active pane. Swap Panels is mode-scoped, so it carries no pane and is
/// enabled only in comparison mode.
@MainActor
final class TitleBarMenuTests: XCTestCase {
    enum ExpectedItem: Equatable {
        case title(String)
        case separator
    }

    /// The menu bar's File submenu. The join commands sit between the save
    /// block and Close in one block: Insert (at the start) and Append (at the
    /// end) grouped together after a separator that closes the save block, then
    /// Duplicate (§23) in a block of its own — the other direction from the
    /// joins, and the one item that is about the window's second pane.
    private let fileMenuItems: [ExpectedItem] = [
        .title("New File"),
        .title("New Window"),
        .title("New Tab"),
        .title("Open…"),
        .separator,
        .title("Save"),
        .title("Save As…"),
        .title("Revert to Saved"),
        .separator,
        .title("Insert File at Start…"),
        .title("Append File…"),
        .separator,
        .title("Duplicate"),
        .separator,
        .title("Close"),
        .title("Close Window"),
    ]

    /// The pane header menu: every File item (the join twins mirroring the
    /// menu bar's File submenu — Insert and Append in one block, then
    /// Duplicate), then the header-only Show in Finder grouped with Close, then
    /// Swap Panels in its own block.
    private var paneMenuItems: [ExpectedItem] {
        [
            .title("New File"),
            .title("Open…"),
            .separator,
            .title("Save"),
            .title("Save As…"),
            .title("Revert to Saved"),
            .separator,
            .title("Insert File at Start…"),
            .title("Append File…"),
            .separator,
            .title("Duplicate"),
            .title("Open in New Tab"),
            .separator,
            .title("Show in Finder"),
            .title("Close"),
            .separator,
            .title("Swap Panels"),
        ]
    }

    private func titlesAndSeparators(of menu: NSMenu) -> [ExpectedItem] {
        menu.items.map { item in
            item.isSeparatorItem ? .separator : .title(item.title)
        }
    }

    // MARK: - App menu bar File submenu

    /// One built File menu, described completely: its items and separators in
    /// order, every real item carrying NO target, and the key equivalent each
    /// one carries.
    ///
    /// The nil target is the point. There is one menu bar per application, so a
    /// File item addressed to one particular window's controller would go on
    /// addressing it after the user moved to another window or tab. Travelling
    /// the responder chain lands the command on whichever `MainViewController`
    /// is key, which is what "acts on the active pane" has to mean once there
    /// is more than one window (§4, §5).
    func testFileMenuCarriesEveryItemWithItsTargetAndKey() {
        let menu = MainMenu.makeFileMenu()

        XCTAssertEqual(titlesAndSeparators(of: menu), fileMenuItems)

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNil(item.target,
                         "\(item.title) must travel the responder chain, not a fixed target")
        }

        // Duplicate carries no key equivalent: ⌘D is Toggle Bookmark (§20).
        // "N" is ⇧⌘N — the capital carries the shift.
        let expectedKeys = ["n", "N", "t", "o", nil, "s", "S", "", nil, "", "", nil, "", nil, "w", "W"]
        let keys = menu.items.map { $0.isSeparatorItem ? nil : $0.keyEquivalent }
        XCTAssertEqual(keys, expectedKeys, "the File menu's key equivalents")
    }

    // MARK: - Pane header context menu

    /// The header menu carries every File item plus the header-only Show in
    /// Finder and the Swap Panels block, and every File item targets
    /// `mainViewController` while pinning the pane it was built for in
    /// `representedObject` — the pane the header that owns the menu is bound to,
    /// not the active pane. Swap Panels is exempt: it is a mode-scoped command
    /// and carries no pane.
    func testPaneMenuCarriesEveryFileItemAndResolvesItsOwnPane() {
        let mvc = MainViewController()
        let pane = mvc.windowModel.pane1
        XCTAssertEqual(titlesAndSeparators(of: mvc.makePaneMenu(for: pane)), paneMenuItems)

        for item in mvc.makePaneMenu(for: pane).items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === mvc,
                          "\(item.title) must target mainViewController")
            if item.action == #selector(MainViewController.swapPanes) {
                XCTAssertNil(item.representedObject,
                             "Swap Panels is mode-scoped and must not carry a pane")
                continue
            }
            guard let carried = item.representedObject as? PaneViewModel else {
                XCTFail("\(item.title) must carry its pane in representedObject")
                continue
            }
            XCTAssertTrue(carried === pane,
                          "\(item.title) must carry the pane the menu was built for")
        }
    }

    /// Swap Panels sits in its own final block (separator before it) and is
    /// enabled only in comparison mode — with a single pane it is meaningless.
    func testPaneMenuSwapPanelsIsSeparateBlockAndModeScoped() throws {
        let mvc = MainViewController()
        _ = mvc.view
        mvc.apply(mode: .singleFile)
        let menu = mvc.makePaneMenu(for: mvc.windowModel.pane1)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles.suffix(3), ["Close", "—", "Swap Panels"],
                       "Swap Panels must be its own final block")

        let swap = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(swap.title, "Swap Panels")
        XCTAssertEqual(swap.action, #selector(MainViewController.swapPanes))
        XCTAssertFalse(mvc.validateMenuItem(swap),
                       "Swap Panels is disabled with a single pane open")

        // Comparison mode: both panes present, so the command is available.
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 16))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 16))
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        try mvc.windowModel.pane1.open(url: url1)
        try mvc.windowModel.pane2.open(url: url2)
        mvc.apply(mode: .comparison)
        XCTAssertTrue(mvc.validateMenuItem(swap),
                      "Swap Panels is enabled in comparison mode")
    }

    /// Show in Finder is a header-only item that needs a file on disk: it is
    /// disabled for an empty pane and for an untitled in-memory document (no
    /// URL to reveal), and enabled once the pane holds a real file.
    func testShowInFinderNeedsAFileOnDisk() throws {
        let mvc = MainViewController()
        let pane = mvc.windowModel.pane1
        let showInFinder = try XCTUnwrap(
            mvc.makePaneMenu(for: pane).items.first { $0.title == "Show in Finder" })
        XCTAssertEqual(showInFinder.action, #selector(MainViewController.showPaneInFinder(_:)))
        XCTAssertTrue(showInFinder.target === mvc)

        // Empty pane: nothing on disk to reveal.
        XCTAssertFalse(mvc.validateMenuItem(showInFinder))

        // Untitled in-memory document: still no URL.
        pane.openUntitled()
        XCTAssertFalse(mvc.validateMenuItem(showInFinder))

        // A real file on disk is revealable.
        let url = try tempFile([UInt8](repeating: 0x41, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        try pane.open(url: url)
        XCTAssertTrue(mvc.validateMenuItem(showInFinder))
    }

    /// The controller wires the menu onto the pane header when it builds a pane,
    /// so a right-click on the header pops the pane-scoped menu.
    func testPaneMenuIsAttachedToThePaneHeader() throws {
        let mvc = MainViewController()
        _ = mvc.view  // loads the view, which applies the empty mode
        mvc.apply(mode: .singleFile)

        let pane = try XCTUnwrap(descendants(of: mvc.view, FilePaneView.self).first)
        let paneMenu = try XCTUnwrap(pane.paneMenu, "a pane must carry its context menu")
        let header = try XCTUnwrap(descendants(of: pane, PaneHeaderView.self).first)
        XCTAssertTrue(header.menu === paneMenu,
                      "the pane header must pop the pane's context menu")
    }

    // MARK: - Helpers

}
