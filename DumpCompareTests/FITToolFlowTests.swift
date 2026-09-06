import XCTest
import FITTool
import FITToolUI
import ToolModuleKit
@testable import DumpCompare

/// The FIT tool-module end to end in the app: a real image with a real table in
/// it, the zones it publishes, and the one repair it makes
/// (`Design/UEFI/FIT_TABLE_FORMAT.md`).
///
/// It drives the module's own controls rather than its session, so what is
/// tested is what a user can reach.
@MainActor
final class FITToolFlowTests: XCTestCase {
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

    /// Opens an image and switches the FIT tool on, waiting for the first parse
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
        controller.tools.activate(FITToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForParse()
        return controller
    }

    /// Waits on the session's own seam rather than on the clock.
    private func waitForParse() throws {
        let session = try XCTUnwrap(controller?.tools.session as? FITToolSession)
        let parsed = expectation(description: "the FIT parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func session() throws -> FITToolSession {
        try XCTUnwrap(controller?.tools.session as? FITToolSession)
    }

    private func button(_ title: String) throws -> NSButton {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSButton.self).first { $0.title == title },
                             "a “\(title)” button in the panel")
    }

    private func entriesTable() throws -> NSTableView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSTableView.self).first)
    }

    /// It is in the shipping app, not only in the tests.
    func testTheAppShipsIt() {
        XCTAssertTrue(ToolRegistry.builtIn.contains { $0.identifier == FITToolModule.identifier },
                      "the registry ships the FIT tool")
    }

    /// The table, the pointer that leads to it, every row, and the microcode a
    /// row points at — all of it outlined in the dump.
    func testTheTableAndWhatItPointsAtAreMarkedInTheDump() throws {
        let controller = try open(FITTestImage.make())
        let zones = controller.windowModel.pane1.zones

        XCTAssertEqual(zones.zones.first { $0.id == "fit.table" }?.range, 0x1000..<0x1020)
        XCTAssertEqual(zones.zones.first { $0.id == "fit.pointer" }?.range, 0xFFC0..<0xFFC4)
        XCTAssertEqual(
            zones.zones.first { $0.id == "fit.target.1" }?.range,
            0x2000..<0x2100
        )
        XCTAssertEqual(try entriesTable().numberOfRows, 2)
    }

    /// What the panel says about an image it understands.
    func testThePanelSaysWhereTheTableIsAndWhatIsInIt() throws {
        _ = try open(FITTestImage.make())
        let display = try session().display

        // No volume top file in a fixture this small, so the reading says it
        // assumed the image is mapped against the top of the address space.
        XCTAssertEqual(
            display.summary,
            "FIT at 0x1000 · 1 entry · addresses assumed · checksum 0x5C"
        )
        XCTAssertEqual(display.rows.map(\.typeText), ["FIT Header", "Microcode"])
        XCTAssertEqual(display.rows[1].targetText,
                       "806EA · rev F0 · 2019-07-15 · 0x2000 · 0x100")
        XCTAssertTrue(display.problems.filter { $0.severity == .error }.isEmpty)
    }

    /// An image with no table at all is a sentence in the panel, not an empty
    /// list the user has to interpret.
    func testAnImageWithNoTableSaysSo() throws {
        _ = try open([UInt8](repeating: 0xAA, count: 0x1000))
        let display = try session().display

        XCTAssertEqual(display.summary, "No FIT table in this file.")
        XCTAssertTrue(display.rows.isEmpty)
        XCTAssertTrue(controller?.windowModel.pane1.zones.zones.isEmpty ?? false)
    }

    /// Picking a row focuses that row's zone, and the dump follows.
    func testPickingARowFocusesItInTheDump() throws {
        let controller = try open(FITTestImage.make())

        try entriesTable().selectRowIndexes([1], byExtendingSelection: false)

        XCTAssertEqual(controller.windowModel.pane1.zones.focus, "fit.row.1")
    }

    /// A row exists to point somewhere, and going there selects the component
    /// and puts *it* in focus — not the row that names it.
    func testGoingToARowsOffsetSelectsTheComponentAndFocusesIt() throws {
        let controller = try open(FITTestImage.make())

        // Neither a double-click nor a right-click can be simulated —
        // `clickedRow` is -1 unless a real mouse put it there — so this drives
        // what both of them call.
        try session().goToTarget(of: 1)

        let selection = try XCTUnwrap(controller.windowModel.pane1.hexSelection())
        XCTAssertEqual(selection.start..<selection.end, 0x2000..<0x2100)
        XCTAssertEqual(controller.windowModel.pane1.zones.focus, "fit.target.1")
    }

    /// Every microcode in the table is outlined in the dump from the moment it
    /// is read, named by the CPUID a bench is hunting for.
    func testEveryMicrocodeIsAZoneNamedByItsCpuid() throws {
        let controller = try open(FITTestImage.make())
        let zones = controller.windowModel.pane1.zones.zones

        XCTAssertEqual(zones.first { $0.id == "fit.target.1" }?.name, "CPUID 806EA")
        XCTAssertEqual(zones.first { $0.id == "fit.target.1" }?.range, 0x2000..<0x2100)
    }

    /// What the right-button menu's first item does.
    func testCopyingTheCpuidPutsItOnThePasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.maxik.tests.fit"))
        FITToolSession.pasteboard = board
        defer { FITToolSession.pasteboard = .general }
        _ = try open(FITTestImage.make())

        try session().copyCPUID(of: 1)

        XCTAssertEqual(board.string(forType: .string), "806EA")

        // The header has no CPUID, and asking for one leaves the board alone.
        try session().copyCPUID(of: 0)
        XCTAssertEqual(board.string(forType: .string), "806EA")
    }

    /// The second defect of §11: a checksum left over from an edit that changed
    /// the table and did not recompute it. One byte, one named undo step, and
    /// the panel re-reads afterwards and stops offering the repair.
    func testFixingTheChecksumWritesOneByteAndUndoesInOneStep() throws {
        let controller = try open(FITTestImage.make(checksum: 0xCC))
        let pane = controller.windowModel.pane1
        XCTAssertNotNil(try session().display.checksumFix)

        try button("Fix Checksum").performClick(nil)
        try waitForParse()

        XCTAssertEqual(try pane.byteStorage?.read(at: 0x100F, length: 1), [0x5C])
        XCTAssertNil(try session().display.checksumFix)

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Fix FIT Checksum")

        try pane.undo()
        try waitForParse()

        XCTAssertEqual(try pane.byteStorage?.read(at: 0x100F, length: 1), [0xCC])
        XCTAssertNotNil(try session().display.checksumFix)
    }

    /// The list of problems is not there when there are none: an empty box
    /// under a table that checks out is a box the user has to work out the
    /// meaning of.
    func testTheProblemListIsOnlyThereWhenThereAreProblems() throws {
        _ = try open(FITTestImage.make())
        let panel = try XCTUnwrap(controller?.tools.panel)
        let problems = descendants(of: panel, NSTableView.self)[1]

        XCTAssertEqual(problems.enclosingScrollView?.isHidden, true)

        _ = try open(FITTestImage.make(checksum: 0xCC))
        let after = try XCTUnwrap(controller?.tools.panel)
        let shown = descendants(of: after, NSTableView.self)[1]

        XCTAssertEqual(shown.enclosingScrollView?.isHidden, false)
        XCTAssertEqual(shown.numberOfRows, 1)
    }

    /// A row the validator complained about is red where the eye lands on it,
    /// not only in the list underneath.
    func testARowWithAProblemIsRed() throws {
        _ = try open(FITTestImage.make(microcodeAddress: 0xFFFF_1000))
        let table = try entriesTable()

        func colour(row: Int) throws -> NSColor? {
            let view = try XCTUnwrap(
                table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView
            )
            return view.textField?.textColor
        }

        XCTAssertEqual(try colour(row: 1), .systemRed)
        XCTAssertEqual(try colour(row: 0), .labelColor)
    }

    /// An address off by one hex digit, landing on bytes that are not
    /// microcode — the defect §11 is a post-mortem of, caught by reading what
    /// the row points at rather than trusting it.
    func testAnAddressPointingAtNothingIsReported() throws {
        // Aligned, inside the image, and pointing at the table itself rather
        // than at the microcode a digit away from it.
        _ = try open(FITTestImage.make(microcodeAddress: 0xFFFF_1000))
        let display = try session().display

        XCTAssertTrue(display.rows[1].hasProblem)
        XCTAssertTrue(display.problems.contains {
            $0.kind == .notMicrocodeAtTheAddress(address: 0xFFFF_1000)
        })
    }
}

/// A 64 KiB image with a FIT in it, built byte by byte — the app suite's own
/// fixture, since the model package's builder does not ship.
private enum FITTestImage {
    static func make(
        checksum: UInt8? = nil,
        microcodeAddress: UInt64? = nil
    ) -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 0x1_0000)
        let diff: UInt64 = 0x1_0000_0000 - 0x1_0000
        image.replaceSubrange(0x2000..<0x2100, with: microcode())

        var table = entry(address: 0x2020_205F_5449_465F, size: 2, type: 0x00, checksumValid: true)
        table += entry(address: microcodeAddress ?? (0x2000 + diff), size: 0, type: 0x01)
        table[0x0F] = checksum ?? (0 &- table.reduce(into: UInt8(0)) { $0 = $0 &+ $1 })
        image.replaceSubrange(0x1000..<(0x1000 + table.count), with: table)

        let pointer: UInt64 = 0x1000 + diff
        for index in 0..<4 {
            image[0xFFC0 + index] = UInt8(truncatingIfNeeded: pointer >> (8 * index))
        }
        return image
    }

    private static func entry(
        address: UInt64,
        size: UInt32,
        type: UInt8,
        checksumValid: Bool = false
    ) -> [UInt8] {
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: address >> (8 * $0)) }
        bytes += (0..<3).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }
        // Reserved, Version 0x0100, Type with the ChecksumValid bit, Checksum.
        bytes += [0, 0x00, 0x01, type | (checksumValid ? 0x80 : 0), 0]
        return bytes
    }

    private static func microcode() -> [UInt8] {
        var bytes: [UInt8] = []
        func u32(_ value: UInt32) {
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        u32(1)                       // HeaderType
        u32(0xF0)                    // UpdateRevision
        bytes += [0x19, 0x20, 0x15, 0x07]   // Year, Day, Month — BCD
        u32(0x0008_06EA)             // ProcessorSignature
        u32(0)                       // Checksum
        u32(1)                       // LoaderRevision
        u32(1)                       // PlatformIds
        u32(0x40)                    // DataSize
        u32(0x100)                   // TotalSize
        u32(0); u32(0); u32(0)       // MetadataSize, UpdateRevisionMin, Reserved
        bytes += [UInt8](repeating: 0x5A, count: 0x100 - bytes.count)
        return bytes
    }
}
