import AppKit
import XCTest
import MEFirmware
import MEAToolUI
@testable import DumpCompare

/// The ME Analyzer tool-module end to end in the app: the automatic analysis on
/// show and on change, the curated tree on the Full Tree tab, the zone a
/// selection publishes, and what an unreachable firmware database does to the
/// panel (`Design/ME_ANALYZER_PANEL.md`).
///
/// No test here touches the network: `MEAToolSession.dataSource` is stubbed
/// before the session is built, the way the engine's own suite does, and the
/// dumps are synthetic — an FPT table and a manifest, built in this file.
@MainActor
final class MEAToolFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    /// A stub data source whose database is always reachable. A pure-FPT parse
    /// never reads it (identification needs a manifest), so this is really the
    /// "healthy MEAnalyzer" stand-in for the analyses that do.
    private struct ReachableSource: MEADataSource {
        func database() async throws -> MEADatabase {
            MEADatabase(revision: 378)
        }
    }

    /// A stub data source whose database fetch fails the way an offline
    /// MEAnalyzer does — the shape the panel's retry affordance exists for.
    private struct OfflineSource: MEADataSource {
        func database() async throws -> MEADatabase {
            throw MEADataError.offline(underlying: "test offline")
        }
    }

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        MEAToolSession.dataSource = ReachableSource()
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        MEAToolSession.dataSource = MEAGitHubDataRepository()
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// Opens a file and turns the ME Analyzer on, waiting for the first
    /// analysis — which runs off the main actor — to land.
    private func open(_ bytes: [UInt8], dataSource: (any MEADataSource)? = nil)
        throws -> MainViewController {
        if let dataSource { MEAToolSession.dataSource = dataSource }
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
        controller.tools.activate(MEAToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        _ = try waitForDisplay(of: session())
        return controller
    }

    private func session() throws -> MEAToolSession {
        try XCTUnwrap(controller?.tools.session as? MEAToolSession)
    }

    /// Waits on the session's own seam rather than on the clock: the analysis
    /// lands, off the main actor, and this returns what it showed — nil when the
    /// read failed, which is itself the news a failure test is waiting for.
    @discardableResult
    private func waitForDisplay(
        of session: MEAToolSession,
        after trigger: () -> Void = {},
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> FirmwareAnalysis? {
        let displayed = expectation(description: "the ME analysis lands")
        var result: FirmwareAnalysis?
        session.onDisplay = { result = $0; displayed.fulfill() }
        trigger()
        wait(for: [displayed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
        return result
    }

    private func panel() throws -> NSView {
        try XCTUnwrap(controller?.tools.panel)
    }

    private func outline() throws -> NSOutlineView {
        let panel = try panel()
        return try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
    }

    /// What a row says in the name column — the only way in to the tree a user
    /// has. The row's model value is not read here: `MEATool` is embedded inside
    /// the module's own UI framework (the test target links `MEAToolUI`, never
    /// the pure target), and an app-suite test drives the module the way a user
    /// does — through what is on screen. What a row is *called* is what its
    /// cell shows, and the shape of the tree itself is the pure target's own
    /// tests' job (`MEAToolTests`).
    private func titleText(_ tree: NSOutlineView, row: Int) -> String? {
        let cell = tree.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? NSTableCellView
        return cell?.textField?.stringValue
    }

    /// What a row says in the summary column — the hex `offset · size` line.
    private func subtitleText(_ tree: NSOutlineView, row: Int) -> String? {
        let cell = tree.view(atColumn: 1, row: row, makeIfNecessary: true)
            as? NSTableCellView
        return cell?.textField?.stringValue
    }

    /// The row whose title is `title`, among the rows currently on screen. The
    /// tree's roots are not fixed in number — the engine surfaces whatever it
    /// decoded (checksums join a plain FPT file) — so rows are found by what
    /// they say, not by a position.
    private func row(ofTitle title: String, in tree: NSOutlineView) -> Int? {
        for row in 0..<tree.numberOfRows where titleText(tree, row: row) == title {
            return row
        }
        return nil
    }

    /// The tab switch — the same control a person clicks. The tree lives on the
    /// second segment, so a test that wants the outline asks for it here.
    private func showFullTree() throws {
        let panel = try panel()
        let tabs = try XCTUnwrap(
            descendants(of: panel, NSSegmentedControl.self).first {
                $0.segmentCount == 2 && $0.label(forSegment: 1) == "Full Tree"
            },
            "the panel's own Summary / Full Tree switch")
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        window?.layoutIfNeeded()
    }

    // MARK: - The app ships it

    func testTheAppShipsIt() {
        XCTAssertTrue(
            ToolRegistry.builtIn.contains { $0.identifier == MEAToolModule.identifier },
            "the registry ships the ME Analyzer"
        )
    }

    // MARK: - A healthy parse

    /// The first tab is the summary: opening a file lands on it with the MEA
    /// default table's own rows on screen. A pure-FPT file is unidentified, so
    /// the table is honest — the identity rows only, no "coming soon" roadmap.
    func testTheSummaryTabShowsTheDefaultTableOnOpen() throws {
        _ = try open(METestImage.fptFile())

        let panel = try panel()
        let tabs = try XCTUnwrap(
            descendants(of: panel, NSSegmentedControl.self).first {
                $0.segmentCount == 2
            })
        XCTAssertEqual(tabs.label(forSegment: 0), "Summary")
        XCTAssertEqual(tabs.label(forSegment: 1), "Full Tree")
        XCTAssertEqual(tabs.selectedSegment, 0)

        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("Family"), "\(text)")
        XCTAssertTrue(text.contains("Size"), "\(text)")
        XCTAssertTrue(text.contains("0x4000 (16384 bytes)"), "\(text)")
    }

    /// An FPT table in a file is a reason the analysis has something to say on
    /// the tree: the regions it lists, each a row standing for real bytes. The
    /// tree opens on the Full Tree tab only.
    func testRegionsAppearOnTheFullTreeTabAndSelectingOnePublishesItsRange()
        throws {
        _ = try open(METestImage.fptFile())

        try showFullTree()
        let tree = try outline()

        // The identity the engine can always name is the first root; the FPT
        // table the file carries is the group that opens into its regions. The
        // file also decoded checksums, so the roots are not only these two — the
        // group is found by what it says rather than by a count of rows.
        XCTAssertEqual(titleText(tree, row: 0), "Firmware")
        let regionsRow = try XCTUnwrap(row(ofTitle: "Regions (FPT)", in: tree))
        XCTAssertEqual(subtitleText(tree, row: regionsRow), "2 regions")

        // Open the group: one row per region, each subtitled by its byte range.
        tree.expandItem(tree.item(atRow: regionsRow))
        XCTAssertEqual(subtitleText(tree, row: try XCTUnwrap(row(ofTitle: "FTUE", in: tree))),
                       "0x1000 · 0x800")
        XCTAssertEqual(subtitleText(tree, row: try XCTUnwrap(row(ofTitle: "rbe", in: tree))),
                       "0x2000 · 0x200")

        // Picking FTUE publishes the bytes it stands for as the one zone,
        // focused — and the selection is not lost to the re-show the selection
        // itself causes.
        let ftueRow = try XCTUnwrap(row(ofTitle: "FTUE", in: tree))
        tree.selectRowIndexes(IndexSet(integer: ftueRow), byExtendingSelection: false)
        let zones = controller?.windowModel.pane1.zones
        XCTAssertEqual(zones?.zones.map(\.id), ["1/0"])
        XCTAssertEqual(zones?.zones.map(\.range), [0x1000..<0x1800])
        XCTAssertEqual(zones?.focus, "1/0")
        XCTAssertEqual(tree.selectedRow, ftueRow,
                       "the selection survives the re-show the selection itself causes")

        // The detail list says the row's own things: its offset and its size.
        let text = descendants(of: try panel(), NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("FTUE"), "\(text)")
        XCTAssertTrue(text.contains("0x800 (2048 bytes)"), "\(text)")
    }

    /// Any change is a reason to read the file again: the analysis is automatic,
    /// and it runs afresh on a content change exactly as on a first open.
    func testAChangeToTheContentRunsTheAnalysisAgain() throws {
        _ = try open(METestImage.fptFile())
        let session = try session()

        // A whole-content change — a reload, the kind of edit that moves every
        // offset — re-parses, and the panel shows a fresh analysis.
        let refreshed = try waitForDisplay(of: session, after: {
            session.contentChanged(.reloaded)
        })
        XCTAssertNotNil(refreshed, "a content change re-runs the analysis")
    }

    // MARK: - Parking

    /// Coming back to the ME Analyzer hands it the tab and the row it was on:
    /// the panel is switchable, not a thing you lose your place in.
    func testComingBackKeepsTheTabAndTheSelection() throws {
        _ = try open(METestImage.fptFile())
        try showFullTree()

        let tree = try outline()
        let regionsRow = try XCTUnwrap(row(ofTitle: "Regions (FPT)", in: tree))
        tree.expandItem(tree.item(atRow: regionsRow))
        let ftueRow = try XCTUnwrap(row(ofTitle: "FTUE", in: tree))
        tree.selectRowIndexes(IndexSet(integer: ftueRow), byExtendingSelection: false)

        // Away to None and back to the ME Analyzer.
        controller?.tools.activate(nil, animated: false)
        XCTAssertEqual(controller?.tools.parkedModuleIdentifiers,
                       [MEAToolModule.identifier])
        controller?.tools.activate(MEAToolModule.identifier, animated: false)
        let restored = try waitForDisplay(of: session())
        XCTAssertNotNil(restored, "coming back parses the file again")

        // The restored session is on the same tab, with the same row chosen —
        // re-found by its path after the re-parse, so the row is selected again
        // and its ancestors opened.
        let panel = try panel()
        let tabs = try XCTUnwrap(descendants(of: panel, NSSegmentedControl.self).first {
            $0.segmentCount == 2 && $0.label(forSegment: 1) == "Full Tree"
        })
        XCTAssertEqual(tabs.selectedSegment, 1, "the parked tab comes back")
        let outlineAfter = try outline()
        let row = outlineAfter.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0, "the parked row comes back selected")
        XCTAssertEqual(titleText(outlineAfter, row: row), "FTUE")
        XCTAssertEqual(controller?.windowModel.pane1.zones.zones.map(\.id), ["1/0"])
    }

    // MARK: - A database the panel cannot reach

    /// An unreachable firmware database is a problem with a remedy: the status
    /// line says so in red and offers Try Again, which re-runs the same failed
    /// read — and, still offline, lands on the same problem.
    func testAnOfflineDatabaseShowsTheProblemAndRetryReAttempts() throws {
        // A manifest-bearing file, so identification asks for MEA.dat at all.
        _ = try open(METestImage.manifestFile(), dataSource: OfflineSource())
        let session = try session()

        // The status line is red and names the failure, and the panel offers
        // the way out.
        let panel = try panel()
        let notice = try XCTUnwrap(
            descendants(of: panel, NSTextField.self).first {
                $0.stringValue.contains("Could not reach the MEAnalyzer repository")
            })
        XCTAssertEqual(notice.textColor, .systemRed)
        let retry = try XCTUnwrap(
            descendants(of: panel, NSButton.self).first { $0.title == "Try Again" })
        XCTAssertFalse(retry.isHidden)
        XCTAssertEqual(controller?.windowModel.pane1.zones.zones.isEmpty ?? true, true,
                       "no analysis, no zone")

        // Try Again re-runs the read — a second display, still the same failure
        // while the source is offline. (Recovery when it is reachable again is
        // the reactivation case above.)
        let retried = try waitForDisplay(of: session, after: {
            retry.performClick(nil)
        })
        XCTAssertNil(retried, "still offline, still no analysis")
        XCTAssertEqual(notice.stringValue.contains("Could not reach the MEAnalyzer repository"),
                       true)
    }
}

// MARK: - The ME image the app-suite parses

/// Synthetic ME region bytes, built by hand — the app suite's own fixtures,
/// since the engine's test fixtures do not ship. Layout mirrors the engine's
/// own `FPTFixture`/`ManifestFixture`.
enum METestImage {
    /// Little-endian `UInt32` at `offset` in `bytes`.
    private static func u32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes[offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// A 0x4000 region: a `$FPT` v2.0 header at its base listing two regions —
    /// FTUE at 0x1000 (0x800 bytes) and rbe at 0x2000 (0x200 bytes) — with the
    /// rest of the region erased. A pure-FPT parse: no manifest, so no database
    /// read, and the tree shows identity + Regions (FPT).
    static func fptFile() -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: 0x4000)

        let header = 0
        for (index, byte) in "$FPT".utf8.enumerated() {
            bytes[header + index] = byte
        }
        u32(2, into: &bytes, at: header + 0x04)     // NumPartitions
        bytes[header + 0x08] = 0x20                 // HeaderVersion
        bytes[header + 0x09] = 0x10                 // EntryVersion
        bytes[header + 0x0A] = 0x20                 // HeaderLength

        // FTUE: 0x1000, 0x800, flags 0x01.
        let ftue = header + 0x20
        for (index, byte) in "FTUE".utf8.enumerated() { bytes[ftue + index] = byte }
        u32(0x1000, into: &bytes, at: ftue + 0x08)
        u32(0x800, into: &bytes, at: ftue + 0x0C)
        u32(0x01, into: &bytes, at: ftue + 0x1C)

        // rbe: 0x2000, 0x200, flags 0. The 4-byte name field is written full,
        // not left to the 0xFF fill: a decoder reads all four bytes, and an
        // erased 0xFF where the terminator should be reads as no name.
        let rbe = header + 0x40
        for (index, byte) in "rbe".utf8.enumerated() { bytes[rbe + index] = byte }
        bytes[rbe + 3] = 0
        u32(0x2000, into: &bytes, at: rbe + 0x08)
        u32(0x200, into: &bytes, at: rbe + 0x0C)
        u32(0, into: &bytes, at: rbe + 0x1C)

        return bytes
    }

    /// A region that is one `$MN2` R1 manifest at its base — enough for the
    /// analysis to reach identification, where the firmware database is read.
    /// With an offline data source that read fails and the panel says so.
    static func manifestFile() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x284)

        func put(_ value: [UInt8], at offset: Int) {
            for (i, b) in value.enumerated() { bytes[offset + i] = b }
        }
        func u16(_ value: UInt16, at offset: Int) {
            put([UInt8(value & 0xFF), UInt8(value >> 8)], at: offset)
        }
        // HeaderLength 0xA1 dwords, R1 header version, Production flags.
        u32(0xA1, into: &bytes, at: 0x04)
        u32(0x1_0000, into: &bytes, at: 0x08)
        u32(0x1, into: &bytes, at: 0x0C)
        u16(0x8086, at: 0x10)                        // VEN_ID — the anchor
        bytes[0x14] = 0x24                           // Day (BCD)
        bytes[0x15] = 0x03                           // Month (BCD)
        u16(0x2021, at: 0x16)                        // Year (BCD)
        put(Array("$MN2".utf8), at: 0x1C)            // Tag
        u32(0x1000_0000, into: &bytes, at: 0x20)     // R1 BuildTag
        u16(15, at: 0x24); u16(40, at: 0x26)
        u16(37, at: 0x28); u16(3121, at: 0x2A)
        u32(3, into: &bytes, at: 0x2C)               // SVN
        u16(15, at: 0x30); u16(40, at: 0x32)         // MEU major/minor
        u16(0, at: 0x34); u16(0, at: 0x36)           // MEU hotfix/build
        u32(0x40, into: &bytes, at: 0x78)            // PublicKeySize (dwords)
        u32(1, into: &bytes, at: 0x7C)               // ExponentSize
        put(Array(0..<0x100).map { UInt8($0 % 0x100) }, at: 0x80)     // RSA key
        put([0x01, 0x00, 0x01, 0x00], at: 0x180)     // Exponent (65537)
        put(Array(0..<0x100).map { UInt8((0xFF - ($0 % 0x100)) & 0xFF) },
            at: 0x184)                                // Signature

        return bytes
    }
}
