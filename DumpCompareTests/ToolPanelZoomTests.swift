import XCTest
import ALSplitView
import FITTool
import FITToolUI
import ToolModuleKit
import UEFIImage
import UEFIToolUI
@testable import DumpCompare

/// The firmware panels read at the app's Zoom: the same View > Zoom In that
/// grows the dump grows the tables and the detail beside it, and a bigger size
/// takes the row height and the column widths with it rather than clipping.
///
/// Both panels are here because the size is one thing they share
/// (`ToolPanelFont`) — a change that reaches one and not the other is the bug
/// this guards.
@MainActor
final class ToolPanelZoomTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        AppearanceSettings.resetToDefaults()
        // Nothing here touches the network, and nothing here should beep.
        FITToolSession.alert = {}
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        FITToolSession.alert = { NSSound.beep() }
        AppearanceSettings.resetToDefaults()
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// Opens an image with `module` switched on, and waits for the first parse
    /// — which happens off the main actor — to land.
    private func open(_ bytes: [UInt8], module: String) throws -> MainViewController {
        let url = try tempFile(bytes)
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(module, animated: false)
        window.layoutIfNeeded()
        return controller
    }

    private func waitForUEFIParse() throws {
        let session = try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func waitForFITParse() throws {
        let session = try XCTUnwrap(controller?.tools.session as? FITToolSession)
        let parsed = expectation(description: "the FIT parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    /// Zooms to `size` the way the View menu does, and lets the panel re-lay
    /// out.
    private func zoom(to size: CGFloat) {
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                              rowHeightScale: AppearanceSettings.rowHeightScale,
                              fontSize: size)
        window?.layoutIfNeeded()
    }

    /// Every text field under `root`, in the order the tree walks them.
    private func fields(under root: NSView) -> [NSTextField] {
        descendants(of: root, NSTextField.self)
    }

    // MARK: - The tree

    /// A row of the tree is drawn at the zoom, in a row tall enough for it,
    /// and both follow a zoom that happens while the panel is open.
    func testTheUEFITreeFollowsTheZoom() throws {
        let controller = try open(UEFITestImage.make(), module: UEFIToolModule.identifier)
        try waitForUEFIParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let outline = try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)

        func rowFont() throws -> NSFont {
            let cell = try XCTUnwrap(
                outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
            )
            return try XCTUnwrap(cell.textField?.font)
        }

        XCTAssertEqual(try rowFont().pointSize, AppearanceSettings.fontSize,
                       "the tree reads at the app's zoom, not at a size of its own")
        let before = outline.rowHeight

        zoom(to: 20)

        XCTAssertEqual(try rowFont().pointSize, 20, "a zoom reaches the rows")
        XCTAssertGreaterThan(outline.rowHeight, before,
                             "a taller row is what keeps the bigger text from being clipped")
        XCTAssertGreaterThan(outline.rowHeight, 20,
                             "a row shorter than its own text clips it")
    }

    /// The tree's header follows too — a 20-point row under an 11-point label
    /// reads as two tables.
    func testTheUEFIHeaderFollowsTheZoom() throws {
        let controller = try open(UEFITestImage.make(), module: UEFIToolModule.identifier)
        try waitForUEFIParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let outline = try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
        let header = try XCTUnwrap(outline.headerView, "the tree names its columns")
        let name = try XCTUnwrap(outline.tableColumn(withIdentifier: .init("name")))
        let width = try XCTUnwrap(outline.tableColumn(withIdentifier: .init("type"))).width

        let heightBefore = header.frame.height

        zoom(to: 20)

        let label = name.headerCell.attributedStringValue
        let font = label.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 20, "a header label is drawn at the zoom")
        XCTAssertGreaterThan(header.frame.height, heightBefore,
                             "the header grows with its label rather than clipping it")
        XCTAssertGreaterThan(
            try XCTUnwrap(outline.tableColumn(withIdentifier: .init("type"))).width, width,
            "a fixed column grows with the text it has to hold"
        )
    }

    /// The detail under the tree is rebuilt at the new size, and the field on
    /// screen when the zoom moved is the field still on screen after.
    func testTheUEFIDetailFollowsTheZoom() throws {
        let controller = try open(UEFITestImage.make(), module: UEFIToolModule.identifier)
        try waitForUEFIParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let outline = try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
        if let root = outline.item(atRow: 0) { outline.expandItem(root) }
        window?.layoutIfNeeded()
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first)
        let detail = try XCTUnwrap(splitter.panes.last)
        let labelled = try XCTUnwrap(
            fields(under: detail).first { $0.stringValue == "Kind" },
            "the detail lists the node's fields"
        )
        XCTAssertEqual(labelled.font?.pointSize, AppearanceSettings.fontSize)

        zoom(to: 20)

        let after = try XCTUnwrap(
            fields(under: detail).first { $0.stringValue == "Kind" },
            "the same field is still listed after a zoom"
        )
        XCTAssertEqual(after.font?.pointSize, 20, "a zoom reaches the detail's rows")
    }

    /// Every column of the tree can be dragged. `resizingMask` is what
    /// decides this — a column whose mask leaves `.userResizingMask` out
    /// cannot be dragged at all, however wide the pointer's grab area looks
    /// and whatever `allowsColumnResizing` says — and the tree's two fixed
    /// columns had an empty mask, so nothing in it could be resized.
    func testTheUEFITreesColumnsCanBeDragged() throws {
        let controller = try open(UEFITestImage.make(), module: UEFIToolModule.identifier)
        try waitForUEFIParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let outline = try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)

        XCTAssertTrue(outline.allowsColumnResizing)
        for column in outline.tableColumns {
            XCTAssertTrue(
                column.resizingMask.contains(.userResizingMask),
                "\(column.identifier.rawValue) cannot be dragged"
            )
        }
    }

    /// A width the user set survives a zoom: the columns move by the ratio the
    /// size moved by, from the widths they have, rather than being recomputed
    /// from the design's.
    func testAWidthTheUserSetSurvivesAZoom() throws {
        let controller = try open(UEFITestImage.make(), module: UEFIToolModule.identifier)
        try waitForUEFIParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let outline = try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
        let type = try XCTUnwrap(outline.tableColumn(withIdentifier: .init("type")))

        // What a drag leaves behind.
        type.width = 200
        let size = AppearanceSettings.fontSize

        zoom(to: 20)

        XCTAssertEqual(type.width, (200 * 20 / size).rounded(), accuracy: 1,
                       "the column the user widened came back to the design's width")
    }

    // MARK: - The table

    /// The FIT entries, its problem list and its detail all read at the zoom.
    func testTheFITPanelFollowsTheZoom() throws {
        let controller = try open(FITTestImage.make(), module: FITToolModule.identifier)
        try waitForFITParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let entries = try XCTUnwrap(descendants(of: panel, NSTableView.self).first)
        entries.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window?.layoutIfNeeded()

        func cellFont(column: Int, row: Int) throws -> NSFont {
            let cell = try XCTUnwrap(
                entries.view(atColumn: column, row: row, makeIfNecessary: true)
                as? NSTableCellView
            )
            return try XCTUnwrap(cell.textField?.font)
        }

        XCTAssertEqual(try cellFont(column: 1, row: 0).pointSize,
                       AppearanceSettings.fontSize,
                       "the table reads at the app's zoom")
        let rowBefore = entries.rowHeight
        let addressBefore = try XCTUnwrap(
            entries.tableColumn(withIdentifier: .init("address"))
        ).width

        zoom(to: 20)

        XCTAssertEqual(try cellFont(column: 1, row: 0).pointSize, 20,
                       "a zoom reaches the entries")
        // The numbers keep their one-width digits at the new size: an address
        // column that stops lining up is worse than a small one.
        let address = try cellFont(column: 2, row: 1)
        XCTAssertEqual(address.pointSize, 20)
        XCTAssertEqual(address, NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular))
        XCTAssertGreaterThan(entries.rowHeight, rowBefore)
        XCTAssertGreaterThan(
            try XCTUnwrap(entries.tableColumn(withIdentifier: .init("address"))).width,
            addressBefore
        )

        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first)
        let detail = try XCTUnwrap(splitter.panes.last)
        let field = try XCTUnwrap(
            fields(under: detail).first { $0.stringValue == "Offset" },
            "the detail lists the row's fields after a zoom"
        )
        XCTAssertEqual(field.font?.pointSize, 20, "a zoom reaches the detail's rows")
    }

    /// A panel that has never been zoomed still reads bigger than the 11
    /// points these panels were first laid out at — the default zoom is the
    /// size, and that is the whole point of reading it.
    func testAPanelStartsBiggerThanItWasLaidOutAt() throws {
        let controller = try open(FITTestImage.make(), module: FITToolModule.identifier)
        try waitForFITParse()
        let panel = try XCTUnwrap(controller.tools.panel)
        let entries = try XCTUnwrap(descendants(of: panel, NSTableView.self).first)
        let cell = try XCTUnwrap(
            entries.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )

        let size = try XCTUnwrap(cell.textField?.font?.pointSize)
        XCTAssertGreaterThan(size, ToolPanelFont.designSize)
        XCTAssertGreaterThan(entries.rowHeight, 17,
                             "AppKit's small row is what the bigger text outgrew")
    }
}
