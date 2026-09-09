import XCTest
import ALSplitView
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
    /// How many times a refusal asked for attention.
    private var beeps = 0

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        // Nothing in this suite touches the network: a test that reaches
        // github.com is a test that fails on a train.
        FITToolSession.microcodeSource = FakeMicrocodeSource()
        // A test suite that beeps is a test suite people run with the volume
        // down.
        beeps = 0
        FITToolSession.alert = { [self] in beeps += 1 }
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        FITToolSession.microcodeSource = CPUMicrocodesRepository()
        FITToolSession.alert = { NSSound.beep() }
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
        // The count includes the header row, so one microcode reads as two.
        XCTAssertEqual(
            display.summary,
            "FIT at 0x1000 · 2 entries · addresses assumed · checksum 0x5C"
        )
        XCTAssertEqual(display.rows.map(\.typeText), ["FIT Header", "Microcode"])
        XCTAssertEqual(display.rows[1].targetText,
                       "CPUID 806EA · r.F0 · 2019-07-15")
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

    /// Picking a row fills the detail below the splitter with what that row is
    /// — the entry's own fields and what its address leads to.
    func testPickingARowFillsTheDetail() throws {
        _ = try open(FITTestImage.make())

        try entriesTable().selectRowIndexes([1], byExtendingSelection: false)
        window?.layoutIfNeeded()

        // The detail is decided in the pure target and rides on the display.
        // The row's number counts from one, so the first microcode — the row
        // after the header — is the second row, not the first.
        let detail = try session().display.detail
        XCTAssertEqual(detail.title, "#2 Microcode")
        XCTAssertTrue(detail.fields.contains { $0.label == "CPUID" && $0.value == "806EA" })
        XCTAssertTrue(detail.fields.contains { $0.label == "Total size" && $0.value == "0x100 (256)" })

        // And it is on screen, not just in the model.
        let panel = try XCTUnwrap(controller?.tools.panel)
        let labels = Set(descendants(of: panel, NSTextField.self).map(\.stringValue))
        XCTAssertTrue(labels.contains("CPUID"), "the detail shows a CPUID label")
        XCTAssertTrue(labels.contains("806EA"), "the detail shows the CPUID value")
    }

    /// The detail is the lower pane of the splitter, at the panel's full
    /// width and with height of its own — a row's fields are not a sliver the
    /// user has to work out is supposed to be there.
    ///
    /// Position, not only height: this asserted height alone while the split
    /// was side by side, and passed the whole time the detail was a
    /// zero-width column down the right-hand edge with the panel's full
    /// height. Height was true for the wrong reason.
    func testTheDetailPanelIsTheLowerPaneAtFullWidth() throws {
        _ = try open(FITTestImage.make())
        try entriesTable().selectRowIndexes([1], byExtendingSelection: false)
        window?.layoutIfNeeded()

        let panel = try XCTUnwrap(controller?.tools.panel)
        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first,
                                     "the panel has a splitter")
        XCTAssertFalse(splitter.isVertical,
                       "the panes are stacked — the table above, the detail below")
        let entries = try XCTUnwrap(splitter.panes.first, "the upper pane is the table")
        let detail = try XCTUnwrap(splitter.panes.last as? NSScrollView,
                                   "the lower pane is the detail")

        XCTAssertGreaterThan(detail.frame.height, 60,
                             "the detail has room to show a row's fields")
        XCTAssertEqual(detail.frame.width, splitter.bounds.width, accuracy: 1,
                       "the detail spans the panel rather than a column beside the table")
        XCTAssertGreaterThanOrEqual(detail.frame.minY, entries.frame.maxY,
                                    "the detail sits below the table, not beside it")
    }

    /// A first open shows the placeholder where the user is looking. The
    /// detail's document view is not flipped by default, so a scroll view
    /// shows the *bottom* of anything taller than itself: without the
    /// document being pinned to the visible area the text landed below the
    /// fold, clipped, and the panel read as empty until the user scrolled up.
    func testTheDetailPlaceholderIsInsideTheVisibleAreaOnAFirstOpen() throws {
        _ = try open(FITTestImage.make())
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

    /// The "FIT at …" title is clickable, and clicking it puts the whole table
    /// in focus and takes the dump there — not a row, since the title stands
    /// for the table.
    func testClickingTheTitleShowsTheWholeTable() throws {
        let controller = try open(FITTestImage.make())
        let pane = controller.windowModel.pane1
        let panel = try XCTUnwrap(controller.tools.panel)

        // The title is the summary label, and it is the one thing in the panel
        // that is clickable.
        let title = try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.hasPrefix("FIT at")
        })
        XCTAssertTrue(
            (title.gestureRecognizers ?? []).contains(where: { $0 is NSClickGestureRecognizer }),
            "the title must be clickable"
        )

        // A click on a label cannot be simulated the way a button's can, so
        // this drives what the click calls.
        try session().showTable()

        XCTAssertEqual(pane.zones.focus, "fit.table")
        XCTAssertEqual(pane.caretOffset, 0x1000)
    }

    /// With no table there is nothing to show, so the title does nothing rather
    /// than clear a focus the user set.
    func testTheTitleDoesNothingWithoutATable() throws {
        _ = try open([UInt8](repeating: 0xAA, count: 0x1000))

        try session().showTable()

        XCTAssertTrue(controller?.windowModel.pane1.zones.zones.isEmpty ?? false)
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

    // MARK: - A parse's progress

    /// The shape the user asked for: while a parse runs, the module's own
    /// bottom row — the line where the notice lives — carries a determinate
    /// bar, and the status bar of the hex pane beside it stays quiet. A parse
    /// runs off the main actor, so seeing the scan's fractions reach the bar
    /// also proves the report found its way back across.
    func testAParseShowsItsProgressInTheModulesOwnRow() throws {
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        // No descriptor and no FIT: the whole image is walked byte by byte —
        // the one slow path in a UEFI parse. 8 MiB keeps it on screen long
        // enough to watch.
        let url = try tempFile([UInt8](repeating: 0xFF, count: 8 << 20))
        files.append(url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(FITToolModule.identifier, animated: false)
        window.layoutIfNeeded()

        let panel = try XCTUnwrap(controller.tools.panel)
        // The bar is in the module's row from the moment the parse starts, and
        // the scan reports each MiB it crosses — so it is moving off zero by
        // the time a few windows have gone.
        XCTAssertTrue(pumpUntil(8) {
            descendants(of: panel, NSProgressIndicator.self).first.map {
                !$0.isHidden && $0.doubleValue > 0
            } ?? false
        }, "a parse must show a moving, determinate bar in the module's own row")

        // Not the hex pane's status bar: that one stays quiet.
        let paneView = try XCTUnwrap(descendants(
            of: window.contentView!, FilePaneView.self).first)
        XCTAssertTrue(paneView.operationView.isHidden,
                      "the hex pane's status bar must not host the module's parse")

        // The parse ends: the bar leaves the row, and the pane is still quiet.
        XCTAssertTrue(pumpUntil(8) {
            descendants(of: panel, NSProgressIndicator.self).isEmpty
        }, "the bar must leave the module's row when the parse finishes")
        XCTAssertEqual(try session().display.summary, "No FIT table in this file.")
        XCTAssertTrue(paneView.operationView.isHidden)
    }

    /// And the idle module keeps the whole row for its notice — the complaint
    /// this design answers was a second bar appearing below the module.
    func testIdleTheModuleHasNoProgressBar() throws {
        _ = try open(FITTestImage.make())
        let panel = try XCTUnwrap(controller?.tools.panel)

        XCTAssertTrue(descendants(of: panel, NSProgressIndicator.self).isEmpty,
                      "no parse running means no bar in the module's row")
    }

    /// The parse that owns the bottom row stands the Add button down for the
    /// whole of it: it refuses while a read is in flight, then comes back as
    /// the reading says. The menu items that modify the table stand down with
    /// it, in `menuNeedsUpdate` — which a test cannot drive, because the
    /// right-click that sets `clickedRow` is not something to simulate. An edit
    /// raced against a parse would land in the panel twice — once as the note
    /// its own re-read earns, once as the note the racing parse earns when it
    /// finishes over it — so the busy read must have the controls to itself.
    func testAParseStandsTheAddButtonDown() throws {
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        let url = try tempFile(FITTestImage.slowButReadable())
        files.append(url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()

        controller.tools.activate(FITToolModule.identifier, animated: false)
        let running = try XCTUnwrap(controller.tools.session as? FITToolSession)
        let parsed = expectation(description: "the slow parse lands")
        running.onDisplay = { _ in parsed.fulfill() }

        // The scan runs off the main actor and this thread has not yielded, so
        // it cannot have finished yet: the parse is busy and the button stands
        // down for it.
        XCTAssertFalse(try button("Add Microcode…").isEnabled,
                       "Add must stand down while a parse runs")

        // The reading lands, the bar leaves, and the button comes back as it
        // says: enabled because the table has rows.
        wait(for: [parsed], timeout: 10)
        running.onDisplay = nil
        window.layoutIfNeeded()

        XCTAssertTrue(try button("Add Microcode…").isEnabled,
                      "the table has rows, so Add is back")
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

    /// The ordinary case at a bench: a newer revision of a CPUID the table
    /// already names. It goes where the old one was, and the table does not
    /// change at all.
    func testANewerRevisionOfAKnownCpuidReplacesItInPlace() throws {
        let controller = try open(FITTestImage.make())
        let pane = controller.windowModel.pane1
        let newer = FITTestImage.microcode(signature: 0x0008_06EA, revision: 0xF1)

        try session().addMicrocode(newer, describedAs: "CPUID 806EA")
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows.count, 2, "replaced, not added a second time")
        XCTAssertEqual(display.rows[1].targetRange, 0x2000..<0x2100)
        XCTAssertTrue(display.rows[1].targetText.contains("r.F1"),
                      "\(display.rows[1].targetText)")
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2100, length: 4),
                       [0xFF, 0xFF, 0xFF, 0xFF], "nothing was written past it")

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Replace Microcode")
    }

    /// And the button says which it will be before it is pressed.
    func testTheFormOffersReplaceForACpuidTheTableAlreadyNames() throws {
        _ = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        try session().withCatalogueSeam { loaded.fulfill() }
        try button("Add Microcode…").performClick(nil)
        wait(for: [loaded], timeout: 5)

        let sheet = try XCTUnwrap(try session().viewController.presentedViewControllers?.first)
        let table = try XCTUnwrap(descendants(of: sheet.view, NSTableView.self).first)
        let add = try XCTUnwrap(descendants(of: sheet.view, NSButton.self)
            .first { $0.title == "Add" || $0.title == "Replace" })

        table.selectRowIndexes([0], byExtendingSelection: false)   // 806EA, in the image
        XCTAssertEqual(add.title, "Replace")

        table.selectRowIndexes([1], byExtendingSelection: false)   // 906EA, not in it
        XCTAssertEqual(add.title, "Add")
    }

    /// A refusal is the one line in this panel the user has to read — they
    /// pressed something and it did not happen — so it is red, and it is
    /// audible. The panel is a narrow strip beside a dump they are reading.
    func testARefusalIsRedAndAudible() throws {
        let controller = try open(FITTestImage.make())

        try session().addMicrocode([UInt8](repeating: 0x5A, count: 0x100), describedAs: "junk")
        try waitUntilTheNoticeSettles()

        XCTAssertEqual(beeps, 1)
        let panel = try XCTUnwrap(controller.tools.panel)
        let notice = try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.contains("does not start with an Intel microcode header")
        })
        XCTAssertEqual(notice.textColor, .systemRed)
    }

    /// And a note about what did happen is neither.
    func testWhatWentRightIsQuiet() throws {
        let controller = try open(FITTestImage.make(checksum: 0xCC))

        try session().fixChecksum()
        try waitForParse()

        XCTAssertEqual(beeps, 0)
        let panel = try XCTUnwrap(controller.tools.panel)
        let notice = try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.hasPrefix("Checksum written")
        })
        XCTAssertEqual(notice.textColor, .secondaryLabelColor)
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

    /// §10, the way a bench wants it back: the row goes, the body goes, and
    /// what followed it in the run moves up into the space with its row
    /// repointed.
    func testRemovingAMicrocodeClosesUpTheRunAndTheTable() throws {
        let controller = try open(FITTestImage.make(extraMicrocode: true))
        let pane = controller.windowModel.pane1
        XCTAssertEqual(try session().display.rows.count, 3)

        try session().removeMicrocode(at: 1)
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows.map(\.typeText), ["FIT Header", "Microcode"])
        XCTAssertEqual(display.rows[1].cpuidText, "906EA", "the second one moved up")
        XCTAssertEqual(display.rows[1].targetRange, 0x2000..<0x2100)
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2100, length: 4),
                       [0xFF, 0xFF, 0xFF, 0xFF], "and the bytes it freed are erased")
        XCTAssertTrue(display.problems.filter { $0.severity == .error }.isEmpty,
                      "\(display.problems.map(\.message))")

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Remove Microcode")
    }

    /// The extent of anything else a row can point at is not something this
    /// tool knows, so it is not removed at all: the refusal is red, and the
    /// row and its bytes stay where they were.
    func testRemovingARowThatIsNotMicrocodeIsRefused() throws {
        let controller = try open(FITTestImage.make(extraACM: true))
        let pane = controller.windowModel.pane1
        let before = try pane.byteStorage?.read(at: 0x2000, length: 4)

        try session().removeMicrocode(at: 2)
        try waitUntilTheNoticeSettles()

        let panel = try XCTUnwrap(controller.tools.panel)
        let notice = try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.contains("Only a microcode entry can be removed")
        })
        XCTAssertEqual(notice.textColor, .systemRed)
        XCTAssertEqual(try session().display.rows.count, 3, "the row is still there")
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x2000, length: 4), before,
                       "the microcode is untouched")
    }

    /// A table needs one microcode entry (§8.7), so the only one is not offered
    /// for removal at all — rather than offered and then refused.
    func testTheLastMicrocodeIsNotOfferedForRemoval() throws {
        _ = try open(FITTestImage.make())
        let rows = try session().display.rows

        XCTAssertFalse(rows[1].canRemove)
        XCTAssertFalse(rows[1].commands.contains { $0.title == "Remove Microcode" })
        XCTAssertFalse(rows[0].canRemove)
    }

    /// A row that is a microcode and not the last one is offered for removal —
    /// the one the menu is for.
    func testAnEntryThatMayGoOffersIt() throws {
        _ = try open(FITTestImage.make(extraMicrocode: true))
        let rows = try session().display.rows

        XCTAssertTrue(rows[2].canRemove)
        XCTAssertTrue(rows[2].commands.contains { $0.title == "Remove Microcode" })
    }

    /// The form opens on the whole catalogue — narrowing it is the form's job,
    /// and the sheet is on screen while it is fetched.
    func testTheAddFormOpensWithTheCatalogue() throws {
        let controller = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        var entries: [MicrocodeCatalogueEntry] = []
        let running = try session()
        running.onCatalogueLoaded = { list in
            entries = list
            loaded.fulfill()
        }

        try button("Add Microcode…").performClick(nil)
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(entries.map(\.cpuidText), ["806EA", "906EA", "800F11"])
        XCTAssertEqual(entries.map(\.vendor), [.intel, .intel, .amd])
        XCTAssertFalse(controller.tools.session.map {
            ($0.viewController.presentedViewControllers ?? []).isEmpty
        } ?? true, "the sheet is on screen")
    }

    /// A FIT names Intel microcode and nothing else, so the form lists nothing
    /// else — and says as much where it cannot be missed, since there is no
    /// vendor picker to imply it.
    func testTheFormListsIntelOnlyAndSaysSo() throws {
        _ = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        try session().withCatalogueSeam { loaded.fulfill() }
        try button("Add Microcode…").performClick(nil)
        wait(for: [loaded], timeout: 5)

        let sheet = try XCTUnwrap(try session().viewController.presentedViewControllers?.first)
        let labels = descendants(of: sheet.view, NSTextField.self).map(\.stringValue)
        let table = try XCTUnwrap(descendants(of: sheet.view, NSTableView.self).first)

        XCTAssertTrue(labels.contains { $0.contains("Intel") }, "\(labels)")
        XCTAssertEqual(table.numberOfRows, 2, "the AMD entry is not offered")
        XCTAssertTrue(descendants(of: sheet.view, NSPopUpButton.self).isEmpty,
                      "no vendor picker: there is nothing to pick")
    }

    // MARK: - Replacing a row

    /// The row's "Replace Microcode": the component the row names is swapped for
    /// another, whatever the new one's CPUID, and the table keeps the same
    /// number of rows — the slot stays, so the one-microcode rule is untouched.
    func testReplacingARowSwapsItsComponentAndKeepsTheRow() throws {
        let controller = try open(FITTestImage.make())
        let pane = controller.windowModel.pane1
        let other = FITTestImage.microcode(signature: 0x000906EA, revision: 0xB4)

        try session().replaceMicrocode(other, at: 1, describedAs: "CPUID 906EA")
        try waitForParse()

        let display = try session().display
        XCTAssertEqual(display.rows.count, 2, "swapped, not a second row added")
        XCTAssertEqual(display.rows[1].cpuidText, "906EA")
        XCTAssertEqual(display.rows[1].targetRange, 0x2000..<0x2100)
        // The signature field, not the header: the first dwords are the same
        // in every Intel microcode, and would not tell the swap from no swap.
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x200C, length: 4),
                       Array(other[0x0C..<0x10]), "the new component is where the old one was")

        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Replace Microcode")

        try pane.undo()
        try waitForParse()

        XCTAssertEqual(try session().display.rows[1].cpuidText, "806EA")
    }

    /// The form, opened from a row's "Replace Microcode", names itself after the
    /// replacing and narrows to the one CPUID the row names — not to everything
    /// the image has.
    func testTheReplaceFormNamesItselfAfterTheReplacing() throws {
        _ = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        try session().withCatalogueSeam { loaded.fulfill() }
        try session().replaceMicrocode(at: 1)
        wait(for: [loaded], timeout: 5)

        let sheet = try XCTUnwrap(try session().viewController.presentedViewControllers?.first)
        let labels = descendants(of: sheet.view, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains("Replace Intel Microcode"), "\(labels)")

        // The narrowing is to the one CPUID the row names, not to the image.
        let checkbox = try XCTUnwrap(descendants(of: sheet.view, NSButton.self)
            .first { $0.title.hasPrefix("Only CPUID") })
        XCTAssertEqual(checkbox.title, "Only CPUID 806EA")
    }

    /// In replace mode the button says what it will do to the row: a pick for
    /// the same processor is an update, anything else a replace.
    func testTheReplaceFormSaysUpdateForTheSameCpuid() throws {
        _ = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        try session().withCatalogueSeam { loaded.fulfill() }
        try session().replaceMicrocode(at: 1)
        wait(for: [loaded], timeout: 5)

        let sheet = try XCTUnwrap(try session().viewController.presentedViewControllers?.first)
        let table = try XCTUnwrap(descendants(of: sheet.view, NSTableView.self).first)
        let button = try XCTUnwrap(descendants(of: sheet.view, NSButton.self)
            .first { $0.title == "Update" || $0.title == "Replace" })

        table.selectRowIndexes([0], byExtendingSelection: false)   // 806EA, the row's own
        XCTAssertEqual(button.title, "Update")

        table.selectRowIndexes([1], byExtendingSelection: false)   // 906EA, another processor
        XCTAssertEqual(button.title, "Replace")
    }

    /// In replace mode the "Only CPUID" narrowing is to the one processor the row
    /// names, and with it on the whole list is that one — so there is nothing
    /// left to search, and the field goes away rather than sit there doing
    /// nothing. Off again, and it is back.
    func testTheReplaceFormHidesTheSearchWhileNarrowedToOneCpuid() throws {
        _ = try open(FITTestImage.make())
        let loaded = expectation(description: "the catalogue arrives")
        try session().withCatalogueSeam { loaded.fulfill() }
        try session().replaceMicrocode(at: 1)
        wait(for: [loaded], timeout: 5)

        let sheet = try XCTUnwrap(try session().viewController.presentedViewControllers?.first)
        let searchField = try XCTUnwrap(descendants(of: sheet.view, NSSearchField.self).first)
        let checkbox = try XCTUnwrap(descendants(of: sheet.view, NSButton.self)
            .first { $0.title.hasPrefix("Only CPUID") })

        // Off to begin with, so the field is here.
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertFalse(searchField.isHidden)

        checkbox.performClick(nil)
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(searchField.isHidden,
                      "the one CPUID is the whole list; there is nothing to search")

        checkbox.performClick(nil)
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertFalse(searchField.isHidden)
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

        try session().fixChecksum()
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

    /// The menu a right-click earns is where the controller's Fix action is
    /// wired to the session — and an unwired closure is a Fix Checksum that
    /// silently does nothing, however well the session's own method works. The
    /// controller's wiring is not something the seam-driven test above reaches,
    /// so this one drives the real menu: the entries table answers a
    /// right-click on the header row — the only row the repair is offered on —
    /// with the menu AppKit assigns it, and firing the item must reach the
    /// session and write.
    ///
    /// A right click needs no simulated mouse: `menu(for:)` is the very method
    /// AppKit calls on a right-click, and it resolves the row under the pointer
    /// and hands back the table's menu; the delegate's `menuNeedsUpdate` —
    /// what AppKit runs just before showing — then fills it from that row.
    func testTheContextMenusFixItemReachesTheSessionAndWrites() throws {
        let controller = try open(FITTestImage.make(checksum: 0xCC))
        let pane = controller.windowModel.pane1
        XCTAssertNotNil(try session().display.checksumFix,
                        "the fixture left the header checksum wrong")
        let table = try entriesTable()
        let win = try XCTUnwrap(window)

        // A right-click on the header row — row 0 — through the same
        // `menu(for:)` AppKit calls, at a point the table maps back to that
        // row. The menu it hands back is the one the controller assigned.
        let rect = table.rect(ofRow: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: win.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        )!
        let menu = try XCTUnwrap(table.menu(for: event),
                                 "a right-click on the header row earns its menu")
        XCTAssertEqual(table.clickedRow, 0, "the click resolved to the header row")

        // Fill the menu exactly as AppKit does before showing it, then read the
        // item the repair is offered through.
        menu.delegate?.menuNeedsUpdate?(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Fix Checksum" })
        XCTAssertTrue(item.isEnabled, "a writable file leaves the fix enabled")

        // Fire the item and wait on the re-parse its own write causes — the
        // same seam the seam-driven test waits on.
        let fixed = expectation(description: "the menu fix's re-parse lands")
        try session().onDisplay = { _ in fixed.fulfill() }
        _ = item.target?.perform(item.action, with: item)
        wait(for: [fixed], timeout: 5)
        try session().onDisplay = nil

        XCTAssertEqual(try pane.byteStorage?.read(at: 0x100F, length: 1), [0x5C],
                       "the click wrote the value the table's checksum expects")
        XCTAssertNil(try session().display.checksumFix,
                     "the panel re-read and stopped offering the repair")
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

    /// The findings list is exactly as tall as its rows, up to eight of them:
    /// a box taller than the one line in it reads as a box with something
    /// missing, and the line inside looks pushed off centre. It has no frame
    /// and no padding — it is a strip of lines under the table — and no
    /// selection, since nothing acts on a selected finding (the double-click
    /// reads the row under the pointer).
    func testTheProblemListIsAsTallAsItsRowsUpToEight() throws {
        _ = try open(FITTestImage.make(checksum: 0xCC))
        let panel = try XCTUnwrap(controller?.tools.panel)
        let problems = descendants(of: panel, NSTableView.self)[1]
        let scroll = try XCTUnwrap(problems.enclosingScrollView)
        window?.layoutIfNeeded()
        let rowHeight = problems.rowHeight + problems.intercellSpacing.height

        XCTAssertEqual(problems.numberOfRows, 1, "the fixture's checksum is the one finding")
        XCTAssertEqual(scroll.frame.height, rowHeight, accuracy: 1,
                       "one finding is one row tall, with nothing left over")
        XCTAssertEqual(scroll.borderType, .noBorder, "no frame around the findings")
        XCTAssertEqual(scroll.frame.minX, 0, accuracy: 0.5,
                       "flush with the panel's leading edge")
        XCTAssertEqual(scroll.frame.maxX, panel.bounds.maxX, accuracy: 1.5,
                       "and with its trailing edge")
        XCTAssertEqual(problems.selectionHighlightStyle, .none, "a finding is read, not picked")

        // Enough findings to outgrow the list: it stops at eight rows and
        // scrolls the rest rather than eating the table above it.
        _ = try open(FITTestImage.make(brokenMicrocodeRows: 10))
        let after = try XCTUnwrap(controller?.tools.panel)
        let longer = descendants(of: after, NSTableView.self)[1]
        let longerScroll = try XCTUnwrap(longer.enclosingScrollView)
        window?.layoutIfNeeded()

        XCTAssertGreaterThan(longer.numberOfRows, 8, "the fixture is meant to overflow")
        XCTAssertEqual(longerScroll.frame.height, 8 * rowHeight, accuracy: 1,
                       "the list stops at eight rows")
    }

    /// A row the validator complained about wears a red warning where the row
    /// says what it is — one triangle in the Type column, with what is wrong
    /// under the pointer — and its text stays the colour every other row's is.
    ///
    /// Not the whole row in red: a red row reads as red *values*, and the
    /// values are fine — it is the row the validator has something to say
    /// about.
    func testARowWithAProblemWearsAWarningInTheTypeColumn() throws {
        _ = try open(FITTestImage.make(microcodeAddress: 0xFFFF_1000))
        let table = try entriesTable()

        func typeCell(row: Int) throws -> NSTableCellView {
            try XCTUnwrap(
                table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView
            )
        }

        let flagged = try typeCell(row: 1)
        let warning = try XCTUnwrap(flagged.imageView, "the Type cell carries the warning")
        XCTAssertFalse(warning.isHidden, "the flagged row wears its warning")
        XCTAssertEqual(flagged.textField?.textColor, .labelColor,
                       "the row's own text is not red any more")
        XCTAssertEqual(warning.toolTip,
                       "No microcode header at 0xFFFF1000, and it is not an empty slot",
                       "the pointer reads what the list below says")

        let clean = try typeCell(row: 0)
        XCTAssertEqual(clean.imageView?.isHidden, true, "a row with nothing wrong wears none")
        XCTAssertEqual(clean.textField?.textColor, .labelColor)
    }

    /// A checksum that does not check out reads red in the detail, the way the
    /// UEFI panel's does — the value alone, not the label beside it.
    func testAnInvalidChecksumIsRedInTheDetail() throws {
        _ = try open(FITTestImage.make(checksum: 0xCC))
        let table = try entriesTable()
        // The checksum byte is the header's, so the header row is the one that
        // shows it.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let panel = try XCTUnwrap(controller?.tools.panel)
        let fields = descendants(of: panel, NSTextField.self)
        let value = try XCTUnwrap(
            fields.first { $0.stringValue.contains("(Invalid") },
            "the header's checksum reads as invalid: \(fields.map(\.stringValue))"
        )
        XCTAssertEqual(value.textColor, .systemRed)
        XCTAssertTrue(value.stringValue.contains("should be 0x"),
                      "and says what the byte should be, not just that it is wrong: "
                      + value.stringValue)

        let label = try XCTUnwrap(fields.first { $0.stringValue == "Checksum" })
        XCTAssertEqual(label.textColor, .secondaryLabelColor,
                       "the label stays as quiet as every other label")
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
    /// `brokenMicrocodeRows` appends microcode rows whose address is unaligned
    /// and points at fill — two findings each, which is how a test gets a
    /// findings list longer than the panel is willing to show.
    static func make(
        checksum: UInt8? = nil,
        microcodeAddress: UInt64? = nil,
        extraACM: Bool = false,
        extraMicrocode: Bool = false,
        brokenMicrocodeRows: Int = 0
    ) -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 0x1_0000)
        let diff: UInt64 = 0x1_0000_0000 - 0x1_0000
        image.replaceSubrange(0x2000..<0x2100, with: microcode())
        if extraMicrocode {
            image.replaceSubrange(
                0x2100..<0x2200, with: microcode(signature: 0x0009_06EA, revision: 0xB4)
            )
        }

        // The header counts itself and every row after it (§4), and the rows
        // never decrease in type (§3) — so the broken microcode rows go in
        // with the microcode ones, before an ACM row.
        let rowCount = 2 + (extraMicrocode ? 1 : 0) + brokenMicrocodeRows + (extraACM ? 1 : 0)
        var table = entry(address: 0x2020_205F_5449_465F,
                          size: UInt32(rowCount),
                          type: 0x00, checksumValid: true)
        table += entry(address: microcodeAddress ?? (0x2000 + diff), size: 0, type: 0x01)
        if extraMicrocode { table += entry(address: 0x2100 + diff, size: 0, type: 0x01) }
        for index in 0..<brokenMicrocodeRows {
            table += entry(address: 0x4001 + UInt64(index) * 0x100 + diff, size: 0, type: 0x01)
        }
        if extraACM { table += entry(address: 0x3000 + diff, size: 0, type: 0x02) }
        table[0x0F] = checksum ?? (0 &- table.reduce(into: UInt8(0)) { $0 = $0 &+ $1 })
        image.replaceSubrange(0x1000..<(0x1000 + table.count), with: table)

        let pointer: UInt64 = 0x1000 + diff
        for index in 0..<4 {
            image[0xFFC0 + index] = UInt8(truncatingIfNeeded: pointer >> (8 * index))
        }
        return image
    }

    /// The same picture eight MiB tall. A UEFI parse of it takes real time —
    /// no descriptor, so the whole image is walked byte by byte — yet it still
    /// ends at a table: two microcodes, and a checksum that is checked and
    /// wrong, so once the scan is over every modification button has a reason
    /// to come back enabled.
    static func slowButReadable() -> [UInt8] {
        let size = 8 << 20
        var image = [UInt8](repeating: 0xFF, count: size)
        let diff = 0x1_0000_0000 - UInt64(size)
        image.replaceSubrange(0x2000..<0x2100, with: microcode())
        image.replaceSubrange(
            0x2100..<0x2200, with: microcode(signature: 0x0009_06EA, revision: 0xB4)
        )

        var table = entry(address: 0x2020_205F_5449_465F,
                          size: 3, type: 0x00, checksumValid: true)
        table += entry(address: 0x2000 + diff, size: 0, type: 0x01)
        table += entry(address: 0x2100 + diff, size: 0, type: 0x01)
        table[0x0F] = 0xCC  // wrong, where the header is read as checked
        image.replaceSubrange(0x1000..<(0x1000 + table.count), with: table)

        let pointer = 0x1000 + diff
        for index in 0..<4 {
            image[size - 0x40 + index] = UInt8(truncatingIfNeeded: pointer >> (8 * index))
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
            "Intel/cpu806EA_plat02_ver000000F0_2019-07-15_PRD_11223344.bin",
            "Intel/cpu906EA_plat02_ver000000B4_2021-01-01_PRD_55667788.bin",
            // A vendor a FIT cannot name, which the form still lists.
            "AMD/cpu00800F11_ver08001129_2017-07-14_4F426450.bin"
        ].compactMap { MicrocodeCatalogue.entry(at: $0, size: 0x100) }
    }

    func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8] {
        FITTestImage.microcode(
            signature: entry.cpuid ?? 0,
            revision: UInt32(entry.revisionText, radix: 16) ?? 0
        )
    }
}

extension XCTestCase {
    /// True when any view under `root` has a size or position Auto Layout
    /// cannot solve — the state that logs "Unable to simultaneously satisfy
    /// constraints" and lands the view wherever the engine's fallback puts it.
    @MainActor func anyAmbiguousLayout(under root: NSView) -> Bool {
        if root.hasAmbiguousLayout { return true }
        return root.subviews.contains { anyAmbiguousLayout(under: $0) }
    }
}
