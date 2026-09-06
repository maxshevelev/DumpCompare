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
        // Nothing in this suite touches the network: a test that reaches
        // github.com is a test that fails on a train.
        FITToolSession.microcodeSource = FakeMicrocodeSource()
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        FITToolSession.microcodeSource = CPUMicrocodesRepository()
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

    /// A row exists to point somewhere, and going there puts the component in
    /// focus — not the row that names it.
    func testGoingToARowsOffsetFocusesTheComponentWithoutSelectingIt() throws {
        let controller = try open(FITTestImage.make())

        // Neither a double-click nor a right-click can be simulated —
        // `clickedRow` is -1 unless a real mouse put it there — so this drives
        // what both of them call.
        try session().goToOffset(of: 1)

        // The outline says "this is what you asked for"; nothing is selected,
        // because the user may be part-way through a selection of their own.
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty)
        XCTAssertEqual(controller.windowModel.pane1.zones.focus, "fit.target.1")
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0x2000)
        XCTAssertEqual(try session().display.rows.first { $0.index == 1 }?.index, 1)
    }

    /// Every microcode in the table is outlined in the dump from the moment it
    /// is read, named by the CPUID a bench is hunting for.
    func testEveryMicrocodeIsAZoneNamedByItsCpuid() throws {
        let controller = try open(FITTestImage.make())
        let zones = controller.windowModel.pane1.zones.zones

        XCTAssertEqual(zones.first { $0.id == "fit.target.1" }?.name, "CPUID 806EA")
        XCTAssertEqual(zones.first { $0.id == "fit.target.1" }?.range, 0x2000..<0x2100)
    }

    /// The trip back: picking a microcode's zone in the dump brings its row to
    /// the front of the panel. The bytes are selected by the host; the row is
    /// the half only the tool-module can do.
    func testPickingAZoneInTheDumpSelectsItsRow() throws {
        let controller = try open(FITTestImage.make())
        let pane = controller.windowModel.pane1
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x2000)
        let item = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Select Zone") })

        XCTAssertEqual(item.title, "Select Zone “CPUID 806EA”")
        controller.selectZone(item)

        XCTAssertEqual(pane.zones.focus, "fit.target.1")
        XCTAssertEqual(try entriesTable().selectedRow, 1)
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x2000..<0x2100)
    }

    // MARK: - Adding and removing

    /// The whole of §9.2 through the panel: the component lands in the erased
    /// space after the last microcode, the table names it, and one ⌘Z takes
    /// all of it back.
    func testAddingAMicrocodeWritesTheComponentAndTheRow() throws {
        let controller = try open(FITTestImage.make())
        let pane = controller.windowModel.pane1
        let component = FITTestImage.microcode(signature: 0x000906EA, revision: 0xB4)

        try session().addMicrocode(component, describedAs: "CPUID 906EA")
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows.count, 3)
        XCTAssertEqual(display.rows[2].cpuidText, "906EA")
        XCTAssertEqual(display.rows[2].targetRange, 0x2100..<0x2200)
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2100, length: 4),
                       Array(component[0..<4]))
        XCTAssertTrue(display.problems.filter { $0.severity == .error }.isEmpty,
                      "\(display.problems.map(\.message))")

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Add Microcode")

        try pane.undo()
        try waitForParse()

        XCTAssertEqual(try session().display.rows.count, 2)
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2100, length: 4), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// A file that is not microcode is refused before anything is written.
    func testAFileThatIsNotMicrocodeIsRefusedWithoutWriting() throws {
        let controller = try open(FITTestImage.make())
        let before = try controller.windowModel.pane1.byteStorage?.read(at: 0x2100, length: 4)

        try session().addMicrocode([UInt8](repeating: 0x5A, count: 0x100), describedAs: "junk")
        try waitUntilTheNoticeSettles()

        XCTAssertEqual(try controller.windowModel.pane1.byteStorage?.read(at: 0x2100, length: 4),
                       before)
        XCTAssertEqual(try session().display.rows.count, 2)
    }

    /// §10: the row goes, an empty slot takes its place in the tail, and the
    /// component it named stays where it is.
    func testRemovingAnEntryLeavesAnEmptySlotAndTheComponent() throws {
        let controller = try open(FITTestImage.make(extraACM: true))
        let pane = controller.windowModel.pane1
        XCTAssertEqual(try session().display.rows.count, 3)

        try session().removeEntry(at: 2)
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows.map(\.typeText), ["FIT Header", "Microcode", "Empty slot"])
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2100, length: 4), [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertTrue(display.problems.filter { $0.severity == .error }.isEmpty)
    }

    /// A table needs one microcode entry (§8.7), so the only one is not offered
    /// for removal at all — rather than offered and then refused.
    func testTheLastMicrocodeIsNotOfferedForRemoval() throws {
        _ = try open(FITTestImage.make())
        let rows = try session().display.rows

        XCTAssertFalse(rows[1].canRemove)
        XCTAssertFalse(rows[1].commands.contains { $0.title == "Remove Entry" })
        XCTAssertFalse(rows[0].canRemove)
    }

    func testAnEntryThatMayGoOffersIt() throws {
        _ = try open(FITTestImage.make(extraACM: true))
        let rows = try session().display.rows

        XCTAssertTrue(rows[2].canRemove)
        XCTAssertTrue(rows[2].commands.contains { $0.title == "Remove Entry" })
    }

    /// The form opens on the catalogue, narrowed to the CPUIDs this image
    /// already names — a dump is for one board.
    func testTheAddFormOpensWithTheCatalogue() throws {
        let controller = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        var entries: [MicrocodeCatalogueEntry] = []
        try session().onCatalogueLoaded = { list in
            entries = list
            loaded.fulfill()
        }

        try button("Add Microcode…").performClick(nil)
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(entries.map(\.cpuidText), ["806EA", "906EA"])
        XCTAssertFalse(controller.tools.session.map {
            ($0.viewController.presentedViewControllers ?? []).isEmpty
        } ?? true, "the sheet is on screen")
    }

    /// Waits for whatever the session does next to settle, for the paths that
    /// deliberately write nothing.
    private func waitUntilTheNoticeSettles() throws {
        let settled = expectation(description: "the session comes back")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
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
enum FITTestImage {
    static func make(
        checksum: UInt8? = nil,
        microcodeAddress: UInt64? = nil,
        extraACM: Bool = false
    ) -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 0x1_0000)
        let diff: UInt64 = 0x1_0000_0000 - 0x1_0000
        image.replaceSubrange(0x2000..<0x2100, with: microcode())

        var table = entry(address: 0x2020_205F_5449_465F, size: extraACM ? 3 : 2,
                          type: 0x00, checksumValid: true)
        table += entry(address: microcodeAddress ?? (0x2000 + diff), size: 0, type: 0x01)
        if extraACM { table += entry(address: 0x3000 + diff, size: 0, type: 0x02) }
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

    /// A microcode image with a correct dword checksum — the editor refuses one
    /// without it.
    static func microcode(signature: UInt32 = 0x0008_06EA, revision: UInt32 = 0xF0) -> [UInt8] {
        var bytes: [UInt8] = []
        func u32(_ value: UInt32) {
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        u32(1)                       // HeaderType
        u32(revision)
        bytes += [0x19, 0x20, 0x15, 0x07]   // Year, Day, Month — BCD
        u32(signature)
        u32(0)                       // Checksum, filled in below
        u32(1)                       // LoaderRevision
        u32(1)                       // PlatformIds
        u32(0x40)                    // DataSize
        u32(0x100)                   // TotalSize
        u32(0); u32(0); u32(0)       // MetadataSize, UpdateRevisionMin, Reserved
        bytes += [UInt8](repeating: 0x5A, count: 0x100 - bytes.count)

        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            sum = sum &+ (UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24)
        }
        let stored = 0 &- sum
        for index in 0..<4 { bytes[0x10 + index] = UInt8(truncatingIfNeeded: stored >> (8 * index)) }
        return bytes
    }
}

/// A catalogue of two, and no network.
private struct FakeMicrocodeSource: MicrocodeSource {
    func catalogue() async throws -> [MicrocodeCatalogueEntry] {
        [
            MicrocodeCatalogue.entry(
                at: "Intel/cpu806EA_plat02_ver000000F0_2019-07-15_PRD_11223344.bin", size: 0x100
            )!,
            MicrocodeCatalogue.entry(
                at: "Intel/cpu906EA_plat02_ver000000B4_2021-01-01_PRD_55667788.bin", size: 0x100
            )!
        ]
    }

    func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8] {
        FITTestImage.microcode(signature: entry.cpuid, revision: entry.revision)
    }
}
