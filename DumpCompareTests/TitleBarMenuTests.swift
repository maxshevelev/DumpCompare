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
    /// block and Close: Insert (at the start) grouped with the edit commands
    /// above it, then a separator, then Append (at the end) in its own block.
    private let fileMenuItems: [ExpectedItem] = [
        .title("New File"),
        .title("Open…"),
        .separator,
        .title("Save"),
        .title("Save As…"),
        .title("Revert to Saved"),
        .title("Insert File at Start…"),
        .separator,
        .title("Append File…"),
        .separator,
        .title("Close"),
    ]

    /// The pane header menu: every File item (the join twins mirroring the
    /// menu bar's File submenu — Insert, then the header-only Show in Finder
    /// in its own block, then Append), then Swap Panels in its own block.
    private var paneMenuItems: [ExpectedItem] {
        [
            .title("New File"),
            .title("Open…"),
            .separator,
            .title("Save"),
            .title("Save As…"),
            .title("Revert to Saved"),
            .title("Insert File at Start…"),
            .separator,
            .title("Show in Finder"),
            .separator,
            .title("Append File…"),
            .separator,
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
    /// order, every real item routing to `mainViewController` (never the nil
    /// target / responder chain, so the menu bar acts on the active pane), and
    /// the key equivalent each one carries.
    ///
    /// Built once on purpose: `MainWindowController.init` calls
    /// `buildMainMenu()`, which assigns `NSApp.mainMenu`, so each instance a
    /// test creates replaces the process's menu bar and leaks its window.
    func testFileMenuCarriesEveryItemWithItsTargetAndKey() {
        let wc = MainWindowController()
        let menu = wc.makeFileMenu()

        XCTAssertEqual(titlesAndSeparators(of: menu), fileMenuItems)

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === wc.mainViewController,
                          "\(item.title) must target mainViewController")
        }

        let expectedKeys = ["n", "o", nil, "s", "S", "", "", nil, "", nil, "w"]
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
