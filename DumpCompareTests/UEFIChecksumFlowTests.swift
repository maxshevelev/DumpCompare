import XCTest
import UEFIImage
import UEFITool
import UEFIToolUI
@testable import DumpCompare

/// The UEFI Structure tool's checksum pass end to end in the app: a volume whose
/// checksum a fixture corrupts, the red `(Invalid)` the detail then reads, the
/// node the session flags, and the Fix Checksum seam that rewrites the byte as
/// one undoable step and clears itself on the re-read its own write caused.
///
/// The context menu cannot be simulated — a right-click is not something
/// XCTest can drive — so what is tested there is the state that drives it: the
/// session's `checksumProblems` and the detail's `(Invalid)`/`(Valid)` text,
/// and the seam the menu item calls. The tree's warning is a view, so it is
/// read off the cell.
@MainActor
final class UEFIChecksumFlowTests: XCTestCase {
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
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        AppearanceSettings.resetToDefaults()
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
        try waitForDisplay()
        return controller
    }

    /// Opens a *file on disk* — the read-only tests need real permissions — and
    /// switches the UEFI tool on the same way `open(_:)` does.
    private func openReadOnly(_ url: URL) throws {
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForDisplay()
    }

    /// Waits on the session's own seam rather than on the clock. With an
    /// expectation already installed this is also what a fix's re-parse is
    /// waited on: the write lands, the module re-reads, and the display is
    /// published again.
    private func waitForDisplay() throws {
        let session = try session()
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

    /// Opens the one top-level row — the volume — so its files are rows of
    /// their own. The tree materializes the branch off the main actor and
    /// reads its checksums after it lands, so this waits on both rather than
    /// on the clock.
    private func openTheVolume() throws {
        let outline = try outline()
        let id = try XCTUnwrap((outline.item(atRow: 0) as? UEFITreeRow)?.id,
                               "the top row stands for a node")
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        let session = try session()
        let checked = expectation(description: "the branch's checksums are read")
        checked.assertForOverFulfill = false
        session.onChecksums = { checked.fulfill() }
        let opened = expectation(description: "the branch is materialized")
        tree.expand(id) { _ in opened.fulfill() }
        wait(for: [opened, checked], timeout: 5)
        session.onChecksums = nil
        // The outline recognises only the item object it holds itself, and the
        // reload the branch caused has replaced the one read above.
        outline.expandItem(outline.item(atRow: 0))
        window?.layoutIfNeeded()
    }

    /// Selects a row the way a click would.
    private func selectRow(_ row: Int) throws {
        try outline().selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The detail's checksum rows read `(Valid)`/`(Invalid)` after the value.
    /// The fixture is a valid volume, so `make()` is the value a fix must
    /// restore.
    private func volumeChecksumBytes(of image: [UInt8]) -> [UInt8] {
        // The volume is the one root of the image, its header at 0x00 and its
        // checksum stored at 0x32..0x34 (§3.3, VolumeParser.checksumOffset).
        Array(image[0x32..<0x34])
    }

    /// The field a parse flags, found by kind so the tests do not assert on an
    /// id scheme that is the parser's to choose.
    private func nodeFlagged(with field: UEFIChecksumField) throws -> (NodeID, Set<UEFIChecksumField>) {
        let problems = try session().checksumProblems
        let entry = try XCTUnwrap(
            problems.first { $0.value.contains(field) },
            "a node should be flagged for \(field), got \(problems)"
        )
        return (entry.key, entry.value)
    }

    /// A corrupted volume checksum reaches the panel as a red reading, not only
    /// as a private flag: the volume's detail row says `(Invalid)` and what the
    /// byte should be.
    func testACorruptedVolumeChecksumIsFlaggedAndReadsInvalid() throws {
        var image = UEFITestImage.make()
        image[0x32] ^= 0xFF
        _ = try open(image)
        let (_, fields) = try nodeFlagged(with: .volume)
        XCTAssertEqual(fields, [.volume])

        // The volume is the one top-level row.
        try selectRow(0)
        let text = descendants(of: try XCTUnwrap(controller?.tools.panel), NSTextField.self)
            .map(\.stringValue)
        let invalid = text.first { $0.contains("(Invalid") }
        XCTAssertNotNil(invalid, "the volume's checksum reads as invalid: \(text)")
        XCTAssertTrue(invalid?.contains("should be 0x") ?? false,
                      "and says what it should be, not just that it is wrong: \(text)")
    }

    /// Fix Checksum recomputes the volume's checksum from the *current* bytes,
    /// writes it as one named undo step, and the re-read its own write caused
    /// stops flagging the node and turns the detail back to `(Valid)`.
    func testFixingAVolumeChecksumWritesTheByteAndClearsTheFlag() throws {
        let pristine = UEFITestImage.make()
        var corrupt = pristine
        corrupt[0x32] ^= 0xFF
        let controller = try open(corrupt)
        let volumeID = try nodeFlagged(with: .volume).0
        let pane = controller.windowModel.pane1

        // Install the expectation first: the fix re-parses off the main actor,
        // and the display it republishes is what says the node cleared.
        let fixed = expectation(description: "the fix's re-parse lands")
        try session().onDisplay = { _ in fixed.fulfill() }
        try session().fixChecksum(for: volumeID)
        wait(for: [fixed], timeout: 5)
        try session().onDisplay = nil

        XCTAssertNil(try session().checksumProblems[volumeID],
                     "the node is no longer flagged once its checksum checks out")
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x32, length: 2),
                       volumeChecksumBytes(of: pristine),
                       "the write restored the value the fixture computed")

        // One named undo step takes it back.
        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Fix Checksum")

        // Focus the volume — the one top-level row — and the detail now reads
        // the checksum as right, while the notice the fix earned survives the
        // very re-read its own write caused.
        try selectRow(0)
        let panel = try XCTUnwrap(controller.tools.panel)
        let note = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(note.contains { $0.contains("Checksum written") }, "\(note)")
        XCTAssertTrue(note.contains { $0.hasSuffix("(Valid)") }, "\(note)")
        XCTAssertFalse(note.contains { $0.contains("(Invalid") }, "\(note)")
    }

    /// A file the user cannot write is one the tool cannot write either: the
    /// refusal leaves the corrupt byte alone and the flag in place.
    func testAFixRefusesOnAReadOnlyFile() throws {
        var corrupt = UEFITestImage.make()
        corrupt[0x32] ^= 0xFF
        let url = try tempFile(corrupt)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try openReadOnly(url)
        let (volumeID, _) = try nodeFlagged(with: .volume)

        try session().fixChecksum(for: volumeID)

        XCTAssertEqual(try session().checksumProblems[volumeID]?.contains(.volume), true,
                       "the refusal wrote nothing, so the flag stays")
        let host = try XCTUnwrap(controller?.windowModel.pane1)
        XCTAssertEqual(try host.byteStorage?.read(at: 0x32, length: 2), volumeChecksumBytes(of: corrupt),
                       "no byte changed")
    }

    /// The warning a flagged row wears in the tree is a view beside the name:
    /// a flagged file (a row that exists, a file being visible where a
    /// folded-away volume is not) shows one, and a clean row beside it shows
    /// none — no triangle left over from a recycled cell.
    func testAFlaggedFileRowWearsAWarningAndACleanOneDoesNot() throws {
        var image = UEFITestImage.make()
        // The file's body-checksum field is at 0x11 of its header, the file at
        // 0x48: 0x59. Under a revision-2 volume with the checksum bit unset the
        // field must read the fixed 0xAA, so a 0 breaks it (§5.4).
        image[0x59] = 0
        _ = try open(image)

        // The file is the volume's first child, so the volume is opened first:
        // its files — and their checksums — are not read until it is.
        try openTheVolume()
        try nodeFlagged(with: .fileBody)
        let flagged = try nameCell(of: 1)
        let warning = try XCTUnwrap(flagged.imageView, "the name cell carries the warning")
        XCTAssertFalse(warning.isHidden, "the flagged row wears its warning")
        XCTAssertNotNil(warning.image, "the warning is a symbol, not an empty view")

        // The padding under the file checks out and shares the cell pool with
        // the row above it.
        let clean = try nameCell(of: 2)
        XCTAssertEqual(clean.imageView?.isHidden, true,
                       "a row that checks out shows no triangle")
    }

    /// A name too long for its column is cut short at the end, never wrapped —
    /// and a flagged row is no exception.
    ///
    /// A wrapped name is what the warning first cost this tree: an
    /// `NSTextAttachment` in the name made the field re-lay-out over two
    /// lines, and a field with no height of its own then grew past its row and
    /// drew over the rows around it — half a GUID under its neighbour's name,
    /// the disclosure arrow buried.
    func testALongNameIsTruncatedAndStaysInsideItsRow() throws {
        var image = UEFITestImage.make()
        image[0x59] = 0
        _ = try open(image)
        try openTheVolume()
        let outline = try outline()
        // Narrower than the GUID the flagged file is named by, so the name has
        // to give somewhere.
        try XCTUnwrap(outline.tableColumn(withIdentifier: .init("name"))).width = 70
        window?.layoutIfNeeded()

        for row in 0..<outline.numberOfRows {
            let cell = try nameCell(of: row)
            let field = try XCTUnwrap(cell.textField)
            XCTAssertEqual(field.maximumNumberOfLines, 1, "row \(row) may take a second line")
            XCTAssertEqual(field.lineBreakMode, .byTruncatingTail, "row \(row)")
            XCTAssertLessThanOrEqual(field.frame.height, outline.rowHeight,
                                     "row \(row)'s name is taller than its row")
            XCTAssertLessThanOrEqual(field.fittingSize.height, outline.rowHeight,
                                     "row \(row)'s name asks for more than one row")
        }
    }

    /// Both the warning and the name start at the leading edge of their column
    /// — the row reads left to right whether it is flagged or not.
    ///
    /// The name shares its cell with the warning, and a cell that hands its
    /// slack to those two views instead of to the name reads as a
    /// right-aligned column: the triangle and the name pushed against the
    /// column's right edge with the empty space in front of them (measured).
    func testAFlaggedRowReadsFromTheLeadingEdgeLikeAnyOther() throws {
        var image = UEFITestImage.make()
        image[0x59] = 0
        _ = try open(image)
        try openTheVolume()
        let outline = try outline()
        // Wider than the GUID the flagged file is named by, so the cell has
        // slack to put in the wrong place.
        try XCTUnwrap(outline.tableColumn(withIdentifier: .init("name"))).width = 600
        window?.layoutIfNeeded()

        let flagged = try nameCell(of: 1)
        flagged.layoutSubtreeIfNeeded()
        let warning = try XCTUnwrap(flagged.imageView)
        let name = try XCTUnwrap(flagged.textField)
        let icon = warning.convert(warning.bounds, to: flagged)
        let text = name.convert(name.bounds, to: flagged)

        XCTAssertEqual(icon.minX, 2, accuracy: 1,
                       "the warning sits at the leading edge of the cell")
        XCTAssertGreaterThanOrEqual(text.minX, icon.maxX,
                                    "the name follows the warning rather than "
                                    + "sitting over it")
        XCTAssertGreaterThan(text.maxX, flagged.bounds.maxX - 4,
                             "the name fills the rest of the cell — the slack "
                             + "goes behind the text, not in front of it")

        // The row under it checks out, and its name starts where the flagged
        // row's warning does.
        let clean = try nameCell(of: 2)
        clean.layoutSubtreeIfNeeded()
        let cleanName = try XCTUnwrap(clean.textField)
        XCTAssertLessThanOrEqual(cleanName.convert(cleanName.bounds, to: clean).minX, 2,
                                 "an unflagged row's name starts at the leading edge")
    }

    /// The warning reads at the panel's type size like everything else in the
    /// tree: a 13-point triangle beside 20-point text reads as a blemish.
    func testTheWarningFollowsTheZoom() throws {
        var image = UEFITestImage.make()
        image[0x59] = 0
        _ = try open(image)
        try openTheVolume()
        let outline = try outline()
        let before = try XCTUnwrap(try nameCell(of: 1).imageView?.frame.height)

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: 20)
        window?.layoutIfNeeded()

        let after = try XCTUnwrap(try nameCell(of: 1).imageView?.frame.height)
        XCTAssertGreaterThan(after, before, "the triangle grew with the text beside it")
        XCTAssertLessThanOrEqual(after, outline.rowHeight, "and still fits its row")
    }

    /// The name cell of `row`, view-based like every other table here.
    private func nameCell(of row: Int) throws -> NSTableCellView {
        let outline = try outline()
        return try XCTUnwrap(
            outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
            "the tree is view-based"
        )
    }

    /// The menu a right-click earns is where the controller's Fix action is
    /// wired to the session — and an unwired closure is a Fix Checksum that
    /// silently does nothing, however well the session's own method works. So
    /// the click is driven for real: the outline answers a right-click on the
    /// flagged row with its menu, and firing the item must reach the session
    /// and write, exactly as AppKit would send it.
    func testTheContextMenusFixItemReachesTheSessionAndWrites() throws {
        var image = UEFITestImage.make()
        image[0x59] = 0 // the file's body checksum field breaks (§5.4)
        _ = try open(image)
        try openTheVolume()
        let (fileID, _) = try nodeFlagged(with: .fileBody)
        let outline = try outline()
        let win = try XCTUnwrap(window)

        // A right-click on the flagged row — the file, under the volume that
        // holds it — through the same `menu(for:)` override AppKit calls, at a
        // point the outline maps back to that row.
        let rect = outline.rect(ofRow: 1)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: win.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        )!
        let menu = try XCTUnwrap(outline.menu(for: event),
                                 "a flagged row earns a Fix Checksum menu")
        let item = try XCTUnwrap(menu.items.first { $0.title == "Fix Checksum" })
        XCTAssertTrue(item.isEnabled, "a writable file leaves the fix enabled")

        // Fire the item and wait on the re-parse its own write causes — the
        // same seam the volume test waits on.
        let fixed = expectation(description: "the menu fix's re-parse lands")
        try session().onDisplay = { _ in fixed.fulfill() }
        _ = item.target?.perform(item.action, with: item)
        wait(for: [fixed], timeout: 5)
        try session().onDisplay = nil

        XCTAssertNil(try session().checksumProblems[fileID],
                     "the flag cleared, so the menu reached the session")
        XCTAssertEqual(try controller?.windowModel.pane1.byteStorage?.read(at: 0x59, length: 1),
                       [0xAA],
                       "the click wrote the value the fixture's volume expects")
    }
}
