import XCTest
import ALSplitView
import ToolModuleKit
import UEFIImage
import UEFIToolUI
@testable import DumpCompare

/// The UEFI Structure tool-module end to end in the app: a real FFSv2 volume in
/// a real image, the tree it parses, the one zone a selection publishes, and the
/// trip back from a zone to its row (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// It drives the module's own controls rather than its session, so what is
/// tested is what a user can reach.
@MainActor
final class UEFIToolFlowTests: XCTestCase {
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
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// Opens an image and switches the UEFI tool on, waiting for the first parse
    /// — which happens off the main actor — to land.
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
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
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForParse()
        return controller
    }

    /// Waits on the session's own seam rather than on the clock.
    private func waitForParse() throws {
        let session = try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func session() throws -> UEFIToolSession {
        try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
    }

    private func outline() throws -> NSOutlineView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
    }

    /// The panel's title: the summary line leading with `prefix` — the clickable
    /// handle to the root the tree folded into it.
    private func summary(_ panel: NSView, prefix: String) throws -> NSTextField {
        try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.hasPrefix(prefix)
        })
    }

    /// It is in the shipping app, not only in the tests.
    func testTheAppShipsIt() {
        XCTAssertTrue(
            ToolRegistry.builtIn.contains { $0.identifier == UEFIToolModule.identifier },
            "the registry ships the UEFI Structure tool"
        )
    }

    /// A parse that has landed but a node nobody has chosen yet draws nothing:
    /// the map is empty, and that is the honest state.
    func testNothingSelectedDrawsNoZone() throws {
        _ = try open(UEFITestImage.make())
        XCTAssertTrue(controller?.windowModel.pane1.zones.zones.isEmpty ?? false,
                      "no selection means no zone")
    }

    /// The tree the parser built is the tree the outline shows, and picking a
    /// node publishes that node and what is inside it — the node's whole range
    /// and its body — with the body in focus. Nothing else: not its header as
    /// a zone of its own, not its children, not its neighbours.
    func testSelectingANodePublishesItsBody() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()

        // The volume is the one root of the whole file, so it folded into the
        // title; its children — the file, the padding that aligns it and the
        // free space — open the outline, and the file is the top row.
        XCTAssertEqual(outline.numberOfRows, 3, "the volume is not a row — its "
                       + "children are the top of the tree")
        XCTAssertEqual(outline.selectedRow, -1, "nothing chosen yet")
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // The file is 0x48..<0x8C: a 0x18-byte FFS header, then its sections.
        let zones = controller.windowModel.pane1.zones
        XCTAssertEqual(zones.zones.map(\.id), ["0.0", "0.0#body"])
        XCTAssertEqual(zones.zones.map(\.range), [0x48..<0x8C, 0x60..<0x8C])
        XCTAssertEqual(zones.focus, "0.0#body",
                       "the body is what the node holds — that is the one drawn "
                       + "as the focus")
    }

    /// The trip back: picking a zone in the dump brings its row to the front
    /// of the tree. The bytes are selected by the host; the row is the half
    /// only the tool-module can do.
    ///
    /// A byte now sits in two of the node's zones — the node and the part it
    /// fell in — so the menu offers both, innermost first, and either of them
    /// leads to the same row.
    func testPickingAZoneInTheDumpSelectsItsRow() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // Publish the file's zones by selecting it — the file is the top row,
        // the volume that held it having folded into the title — then pick one
        // back in the dump the way the right-click menu does.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // 0x60 is the first byte of the file's body (the file is 0x48..<0x8C).
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x60)
        let parent = try XCTUnwrap(menu.items.first { $0.title == "Select Zone" })
        let submenu = try XCTUnwrap(parent.submenu, "two zones cover the byte")
        XCTAssertEqual(submenu.items.map(\.title), ["MyDriver body", "MyDriver"],
                       "the innermost zone is offered first")

        controller.selectZone(submenu.items[0])
        XCTAssertEqual(pane.zones.focus, "0.0#body")
        XCTAssertEqual(outline.selectedRow, 0)
        var selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x60..<0x8C,
                       "the body's bytes, not the whole file's")

        // The node's own zone from the same menu: the same row, the whole of it.
        controller.selectZone(submenu.items[1])
        XCTAssertEqual(outline.selectedRow, 0)
        selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x48..<0x8C)
    }

    /// The file is a lone FFSv2 volume off a chip — the parser invents no image
    /// root around a single top, the volume *is* the root — and a root that
    /// holds the whole file does no work as a row: it folds into the title the
    /// way any single root with children does, whatever its kind or its header.
    /// Its children open the tree, and the title names the root by the words
    /// its row would have shown.
    func testALoneVolumeFoldsIntoTheTitleAndItsChildrenOpenTheTree() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The volume's children — the file, the padding that aligns it, and the
        // free space — are the top of the tree. No row reads the volume.
        XCTAssertEqual(outline.numberOfRows, 3)
        let kinds = (0..<outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? UEFINode)?.kind
        }
        XCTAssertEqual(kinds, [.file, .padding, .freeSpace],
                       "the volume folded into the title, leaving its children "
                       + "as the top of the tree")

        // The title names the folded root by its type, and is the clickable
        // handle to it.
        let title = try summary(panel, prefix: "Volume · FFSv2 ·")
        XCTAssertEqual(title.toolTip, "Show the whole image in the dump")
    }

    /// The folded root's one job is to say what the image is, and the title now
    /// says it: clicking the title behaves exactly like a click on the root's
    /// row would — its zones, its detail. The root has no row, so nothing in
    /// the tree is selected, and the title itself reads as selected.
    func testClickingTheTitleSelectsTheFoldedRoot() throws {
        let controller = try open(UEFITestImage.make())
        let pane = controller.windowModel.pane1
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The title is the summary label, and it is the one thing in the panel
        // that is clickable.
        let title = try summary(panel, prefix: "Volume · FFSv2 ·")
        XCTAssertTrue(
            (title.gestureRecognizers ?? []).contains(where: { $0 is NSClickGestureRecognizer }),
            "the title must be clickable"
        )

        // A click on a label cannot be simulated the way a button's can, so
        // this drives what the click calls.
        try session().showTopNode()

        // The folded root is the volume, a real node with a header of its own:
        // selecting it publishes the volume and its body, with the body in
        // focus — exactly what the volume's row used to publish.
        XCTAssertEqual(pane.zones.zones.map(\.id), ["0", "0#body"])
        XCTAssertEqual(pane.zones.zones.map(\.range), [0..<0x1000, 0x48..<0x1000])
        XCTAssertEqual(pane.zones.focus, "0#body")
        XCTAssertEqual(outline.selectedRow, -1, "the folded root has no row to select")

        // The detail says the node in focus is the volume, which spans the
        // whole file.
        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("0x0 · 0x1000 bytes"), "\(text)")
        XCTAssertEqual(title.textColor, .controlAccentColor,
                       "the folded-away root reads as selected in the title")
    }

    /// A file with no root to fold — one that is a single leaf, padding the
    /// whole file — shows that leaf as its one row and hides nothing. The title
    /// has nothing to select, so clicking it does nothing rather than clear a
    /// focus the user set.
    func testTheTitleDoesNothingWhenThereIsNothingToFold() throws {
        let controller = try open([UInt8](repeating: 0xFF, count: 0x1000))
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // Select the one padding row, so there is a focus to keep.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(pane.zones.focus, "0")

        try session().showTopNode()

        XCTAssertEqual(pane.zones.focus, "0",
                       "nothing is hidden in the title, so the click leaves the "
                       + "selection alone")
    }

    /// The bottom of the panel says what the node in focus is, by its type: a
    /// volume by its file system and length, a file by its type and state.
    /// A row's text sits down the middle of the row. The tree is view-based
    /// for that reason: `objectValueFor` is the cell-based path, and an
    /// `NSTextFieldCell` draws its text against the top of the row, which
    /// reads as every row in the tree sitting too high.
    ///
    /// This also guards the focus ring, which is why there is no test of its
    /// own for that. A cell-based table draws a ring around the whole of
    /// itself when it takes focus — `NSCell`-era behaviour — while a
    /// view-based one leaves focus to the selection highlight. That ring was
    /// this tree's, and no other table in the project has ever shown one
    /// because no other table was ever cell-based. Asserting
    /// `focusRingType == .none` instead would only have restated a line of
    /// setup; asserting the cell view is the thing that decides.
    /// Name is the column the reader is after — a GUID or a catalogue name —
    /// so it starts wider than Type and Subtype put together, and those two
    /// start no wider than the short words they hold.
    func testNameStartsWiderThanTheTwoTypeColumns() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        func width(_ identifier: String) throws -> CGFloat {
            try XCTUnwrap(outline.tableColumn(withIdentifier: .init(identifier))).width
        }
        let name = try width("name")
        let type = try width("type")
        let subtype = try width("subtype")

        XCTAssertGreaterThan(name, type + subtype,
                             "the tree spends its width on the two columns that "
                             + "say one short word each")
        // Wide enough for the longest word each column shows on a normal row
        // ("Free space", "Empty (FFh)"), and not much wider.
        let font = ToolPanelFont.body()
        func rendered(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        XCTAssertGreaterThan(type, rendered("Free space"))
        XCTAssertLessThan(type, rendered("Free space") * 1.5)
        XCTAssertGreaterThan(subtype, rendered("Empty (FFh)"))
        XCTAssertLessThan(subtype, rendered("Empty (FFh)") * 1.5)
    }

    func testATreeRowsTextIsCentredInTheRow() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        let cell = try XCTUnwrap(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView,
            "the tree is view-based — cell-based rows have no view here at all"
        )
        let field = try XCTUnwrap(cell.textField, "the cell shows its text in a field")
        // In the cell's own coordinates: the name shares a row with the
        // wrong-checksum warning, so its field is not a direct subview of the
        // cell and its frame is not measured against the cell's bounds.
        let text = field.convert(field.bounds, to: cell)
        let above = text.minY
        let below = cell.bounds.height - text.maxY

        XCTAssertEqual(above, below, accuracy: 1,
                       "\(above) above the text and \(below) below it — the row's "
                       + "text is not centred")
    }

    /// The detail is the lower pane of the splitter, at the panel's full
    /// width and with height of its own. Position, not only height: while the
    /// split was side by side the detail was a zero-width column down the
    /// right-hand edge, which is a panel with no detail at all.
    func testTheDetailPanelIsTheLowerPaneAtFullWidth() throws {
        _ = try open(UEFITestImage.make())
        window?.layoutIfNeeded()

        let panel = try XCTUnwrap(controller?.tools.panel)
        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first,
                                     "the panel has a splitter")
        XCTAssertFalse(splitter.isVertical,
                       "the panes are stacked — the tree above, the detail below")
        let outline = try XCTUnwrap(splitter.panes.first, "the upper pane is the tree")
        let detail = try XCTUnwrap(splitter.panes.last as? NSScrollView,
                                   "the lower pane is the detail")

        XCTAssertGreaterThan(detail.frame.height, 60,
                             "the detail has room to show a node's fields")
        XCTAssertEqual(detail.frame.width, splitter.bounds.width, accuracy: 1,
                       "the detail spans the panel rather than a column beside the tree")
        XCTAssertGreaterThanOrEqual(detail.frame.minY, outline.frame.maxY,
                                    "the detail sits below the tree, not beside it")
    }

    /// A first open shows the placeholder where the user is looking. A scroll
    /// view's document is not flipped by default, so it shows the *bottom* of
    /// anything taller than itself: the text used to land below the fold,
    /// clipped, and the panel read as empty until the user scrolled up.
    func testTheDetailPlaceholderIsInsideTheVisibleAreaOnAFirstOpen() throws {
        _ = try open(UEFITestImage.make())
        let panel = try XCTUnwrap(controller?.tools.panel)

        let placeholder = try XCTUnwrap(
            descendants(of: panel, NSTextField.self)
                .first { $0.stringValue.contains("to see what it is") },
            "nothing selected yet, so the detail says what to do"
        )
        let scroll = try XCTUnwrap(
            descendants(of: panel, ToolDetailScroll.self).first,
            "the placeholder lives in the detail scroll"
        )
        let document = try XCTUnwrap(scroll.documentView)
        let text = placeholder.convert(placeholder.bounds, to: document)

        XCTAssertTrue(scroll.documentVisibleRect.contains(text),
                      "the placeholder is on screen, not below the fold: "
                      + "\(text) is not inside \(scroll.documentVisibleRect)")
        XCTAssertFalse(anyAmbiguousLayout(under: panel),
                       "no view in the panel is left without a size the engine can solve")
    }

    func testTheDetailSaysWhatTheNodeIs() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The volume is the root the tree folded into the title — it has no
        // row — so it is read the way its row would be read, through the click
        // the title stands in for.
        try session().showTopNode()
        var text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("0x0 · 0x1000 bytes"), "\(text)")
        XCTAssertTrue(text.contains("Revision"), "\(text)")

        // The file is a top row of its own: named by its user-interface
        // section, typed by the code in its header.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("MyDriver"), "\(text)")
        XCTAssertTrue(text.contains("Driver"), "\(text)")
    }
}

/// A 4 KiB FFSv2 volume with one sectioned file in it, built byte by byte — the
/// app suite's own fixture, since the parser package's builders do not ship.
///
/// The layout the parse is checked against:
///
/// ```
/// 0x00  volume header, 0x48 long: base header + a two-entry block map
/// 0x48  file "MyDriver" (0x44)
/// 0x60    name section "MyDriver"
/// 0x78    raw section
/// 0x8C  padding to the next eight-byte boundary
/// 0x90  free space to the end of the volume
/// ```
///
/// `HeaderLength` covers the block map, so the body starts at `ALIGN8(0x48)` —
/// past the map, on the first file (§3.2).
enum UEFITestImage {
    static func make() -> [UInt8] {
        let volumeLength: UInt64 = 0x1000
        var image = [UInt8](repeating: 0xFF, count: Int(volumeLength))

        // The volume header: the file system GUID, the length, the signature,
        // the erase polarity, and a block map that agrees with the length.
        // `HeaderLength` spans the base header and the block map, so the body
        // starts past it (§3.2).
        var header: [UInt8] = []
        header += [UInt8](repeating: 0, count: 0x10)
        header += KnownGUIDs.ffsV2.bytes
        header += u64(volumeLength)
        header += u32(0x4856_465F)          // _FVH
        header += u32(0x0000_0800)          // erase polarity
        header += u16(0x48)                 // header length, over the block map
        header += u16(0)                    // checksum, filled in below
        header += u16(0)                    // no extended header
        header += [0, 2]                    // reserved, revision 2
        header += u32(1)                    // block map: one block…
        header += u32(UInt32(volumeLength)) // …of this size
        header += u32(0)                    // …terminated by the {0, 0} pair
        header += u32(0)
        // The sum covers the whole `HeaderLength` (§3.3).
        let checksum = Checksums.checksum16(header) ?? 0
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)
        image.replaceSubrange(0x00..<0x48, with: header)

        // The file: a driver, named by its user-interface section.
        image.replaceSubrange(0x48..<0x8C, with: file())
        return image
    }

    /// The one file in the volume: a 0x44-byte driver whose body is a name
    /// section and a raw section.
    private static func file() -> [UInt8] {
        let name = EFIGUID(low: 0x0000_0000_0000_0001, high: 0x0000_0000_0000_0002)
        var bytes: [UInt8] = []
        bytes += name.bytes
        bytes += [0, 0xAA, 0x07, 0x00]      // header/body checksum, type, attributes
        bytes += u24(0x44)                  // size
        bytes += [0xF8]                     // state, erase polarity

        // Name section: the UCS-2 string a person gave the file.
        bytes += u24(0x16)
        bytes += [0x15]
        bytes += ucs2("MyDriver")

        // Two erased bytes to the next four-byte boundary.
        bytes += [0xFF, 0xFF]

        // Raw section: sixteen bytes of payload.
        bytes += u24(0x14)
        bytes += [0x19]
        bytes += [UInt8](repeating: 0x5A, count: 16)
        return bytes
    }

    // MARK: - Little-endian writers

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u24(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    /// UCS-2 little-endian, with the terminating zero the section carries.
    private static func ucs2(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in string.unicodeScalars {
            bytes += [UInt8(truncatingIfNeeded: scalar.value), 0]
        }
        bytes += [0, 0]
        return bytes
    }
}
