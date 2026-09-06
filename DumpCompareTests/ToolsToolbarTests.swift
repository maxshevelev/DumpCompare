import XCTest
import ToolModuleKit
@testable import DumpCompare

/// The Tools pull-down in the window toolbar (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolsToolbarTests: XCTestCase {
    private var url: URL?
    private var windowController: MainWindowController?

    override func setUp() {
        super.setUp()
        installToolStubs()
    }

    override func tearDown() {
        windowController?.mainViewController.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
        windowController?.close()
        windowController = nil
        url = nil
        super.tearDown()
    }

    private func makeWindow(open: Bool = true) throws -> MainWindowController {
        let wc = MainWindowController()
        windowController = wc
        wc.window?.setContentSize(NSSize(width: 1000, height: 600))
        if open {
            let file = try tempFile([UInt8](repeating: 0xFF, count: 0x40))
            url = file
            try wc.mainViewController.windowModel.pane1.open(url: file)
            wc.mainViewController.apply(mode: .singleFile)
        }
        wc.window?.layoutIfNeeded()
        return wc
    }

    private func toolsButton(_ wc: MainWindowController) throws -> NSPopUpButton {
        let item = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier == .tools },
                                 "a Tools item in the toolbar")
        return try XCTUnwrap(item.view as? NSPopUpButton)
    }

    /// The panel opens on the left, so its control sits on the left.
    func testToolsIsTheLeftmostItem() throws {
        let wc = try makeWindow()

        let identifiers = try XCTUnwrap(wc.window?.toolbar?.items.map(\.itemIdentifier))

        XCTAssertEqual(identifiers.first, .tools)
        XCTAssertEqual(identifiers.dropFirst().first, .space,
                       "a fixed space separates it from the commands")
    }

    func testItOffersTheSameListAsTheMenuBar() throws {
        let wc = try makeWindow()
        let button = try toolsButton(wc)

        let offered = button.menu?.items.dropFirst().map(\.title)

        XCTAssertEqual(Array(offered ?? []), MainMenu.makeToolsMenu().items.map(\.title),
                       "the pull-down's rows are the Tools menu's, past its own title row")
    }

    /// The toolbar draws no labels, so the item has to say which tool-module is
    /// running in the row it displays.
    func testTheButtonNamesTheActiveModule() throws {
        let wc = try makeWindow()
        let button = try toolsButton(wc)
        let item = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier == .tools })

        item.validate()
        XCTAssertEqual(button.menu?.items.first?.title, "",
                       "at rest it is the wrench alone — the toolbar has to fit the launch width")

        wc.mainViewController.tools.activate(StubToolB.identifier, animated: false)
        item.validate()

        XCTAssertEqual(button.menu?.items.first?.title, StubToolB.title)
    }

    func testItCarriesTheWrench() throws {
        let wc = try makeWindow()
        let button = try toolsButton(wc)

        let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        XCTAssertNotNil(button.menu?.items.first?.image)
        XCTAssertEqual(button.menu?.items.first?.image?.size, symbol?.size)
    }

    /// A tool-module needs a file, exactly as its menu row does.
    func testTheItemIsDisabledWithNoFileOpen() throws {
        let wc = try makeWindow(open: false)
        let item = try XCTUnwrap(wc.window?.toolbar?.items.first { $0.itemIdentifier == .tools })

        item.validate()

        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(try toolsButton(wc).isEnabled)
    }
}
