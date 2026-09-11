import AppKit
import XCTest
import MEFirmware
import MEAToolUI
import ToolModuleKit
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
    /// The zoom as the user left it: one test moves it, and the app's zoom is
    /// a real preference rather than something this suite may keep.
    private var zoomSize: CGFloat = ToolPanelFont.defaultSize

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
        zoomSize = AppearanceSettings.fontSize
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        MEAToolSession.dataSource = MEAGitHubDataRepository()
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: zoomSize)
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// Opens a file and turns the ME Analyzer on, waiting for the first
    /// analysis — which runs off the main actor — to land.
    private func open(_ bytes: [UInt8], dataSource: (any MEADataSource)? = nil)
        throws -> MainViewController {
        let controller = try openWithoutWaiting(bytes, dataSource: dataSource)
        _ = try waitForDisplay(of: session())
        return controller
    }

    /// The same open, stopping the moment the analysis has been asked for. It
    /// runs off the main actor, so this is the panel as a user sees it *while*
    /// the ME region is being read — the state the empty tab speaks for.
    private func openWithoutWaiting(_ bytes: [UInt8],
                                    dataSource: (any MEADataSource)? = nil)
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

    /// The Summary tab's two ways out, in its own row against the trailing
    /// edge: the rows as rich text to paste, and the whole page as a picture.
    /// They belong to that tab — the tree has no one page to hand over — so
    /// they go with it.
    func testTheSummaryTabCopiesItsRowsAndItsPicture() throws {
        _ = try open(METestImage.fptFile())
        let panel = try panel()
        let pasteboard = NSPasteboard.general
        let restored = pasteboard.string(forType: .string)
        addTeardownBlock {
            pasteboard.clearContents()
            if let restored { pasteboard.setString(restored, forType: .string) }
        }

        let copy = try button(named: "Copy Summary", in: panel)
        let picture = try button(named: "Copy Screenshot", in: panel)
        let tabs = try XCTUnwrap(
            descendants(of: panel, NSSegmentedControl.self).first { $0.segmentCount == 2 })
        XCTAssertTrue(isOnScreen(copy, under: panel), "both are up on the Summary tab")
        XCTAssertTrue(isOnScreen(picture, under: panel))
        let inPanel = { (view: NSView) in view.convert(view.bounds, to: panel) }
        XCTAssertGreaterThan(inPanel(copy).minX, inPanel(tabs).maxX,
                             "they sit after the switch, not over it")
        XCTAssertEqual(inPanel(picture).maxX, panel.bounds.maxX - 8, accuracy: 2,
                       "and against the trailing edge")
        XCTAssertEqual(inPanel(copy).midY, inPanel(tabs).midY, accuracy: 2,
                       "on the switch's own line")

        // Copy: the rows as rich text, with the plain spelling under it.
        copy.performClick(nil)
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf), "rich text, not only a string")
        let pasted = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertTrue(pasted.string.contains("Family\t"), "a row is a label and its value: \(pasted.string)")
        XCTAssertTrue(pasted.string.contains("0x4000 (16384 bytes)"), pasted.string)
        XCTAssertEqual(pasteboard.string(forType: .string), pasted.string,
                       "and a plain-text field gets the same rows")

        // Screenshot: all of the summary, not the part on screen. The window is
        // made short first, so the summary really does outgrow the area it is
        // shown in and "the whole of it" is a claim with something behind it.
        let window = try XCTUnwrap(self.window)
        window.setContentSize(NSSize(width: window.frame.width, height: 180))
        zoom(to: ToolPanelFont.sizeRange.upperBound)
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(
            descendants(of: panel, ToolDetailScroll.self).first { !$0.isHidden })
        XCTAssertGreaterThan(scroll.content.bounds.height, scroll.contentView.bounds.height,
                             "the premise: the summary no longer fits the visible area")

        picture.performClick(nil)
        let image = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
            "a picture on the clipboard")
        // Cropped to the rows, with an even margin: the list they scroll in is
        // as wide as the panel and never shorter than the visible area, so
        // picturing *it* would be the summary in a field of empty background.
        XCTAssertEqual(image.size.height - scroll.content.bounds.height,
                       image.size.width - scroll.content.bounds.width, accuracy: 1,
                       "the same margin on both axes, and no more")
        XCTAssertGreaterThan(image.size.height, scroll.content.bounds.height,
                             "all of the rows are in it")
        XCTAssertLessThan(image.size.height - scroll.content.bounds.height, 40,
                          "and little else")

        // And it is a picture, not a wash: opaque, on the background the panel
        // shows the rows against. A dark panel draws pale rows, so a background
        // resolved in the wrong appearance pastes them onto white — which is
        // what the clipboard got before.
        panel.appearance = NSAppearance(named: .darkAqua)
        window.layoutIfNeeded()
        pasteboard.clearContents()
        picture.performClick(nil)
        let dark = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage)
        let corner = try XCTUnwrap(
            (try XCTUnwrap(dark.tiffRepresentation).flatMap { NSBitmapImageRep(data: $0) })?
                .colorAt(x: 2, y: 2),
            "the picture's own background pixel")
        XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.01, "nothing shows through it")
        XCTAssertLessThan(corner.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1, 0.5,
                          "a dark panel's picture is dark, not white")
        panel.appearance = nil

        // The Full Tree tab has no page to hand over, so they go with the tab.
        try showFullTree()
        XCTAssertFalse(isOnScreen(copy, under: panel))
        XCTAssertFalse(isOnScreen(picture, under: panel))
    }

    /// The panel's button carrying `name` — the accessibility label, which is
    /// what an icon-only button says it is.
    private func button(named name: String, in panel: NSView) throws -> NSButton {
        try XCTUnwrap(
            descendants(of: panel, NSButton.self).first { $0.accessibilityLabel() == name },
            "no button called \"\(name)\" in the panel")
    }

    /// "Reading…" is the line under the panel while a parse runs — and only
    /// while it runs. Once the analysis lands the line returns to empty, as the
    /// other panels' do, so the busy reading is not mistaken for a result that
    /// is still coming.
    func testTheReadingNoticeIsClearedOnceTheAnalysisLands() throws {
        _ = try open(METestImage.fptFile())

        let panel = try panel()
        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertFalse(text.contains("Reading…"),
                       "a finished analysis is not still 'Reading…': \(text)")
    }

    /// The wait belongs to whichever tab is open, not to Summary alone: on Full
    /// Tree an analysis that has not landed is an empty outline, which says
    /// nothing about whether one is coming. The same icon and words stand in
    /// for the tree until it has rows, and step aside the moment it does.
    func testTheFullTreeTabSaysTheSameWhileTheAnalysisRuns() throws {
        _ = try openWithoutWaiting(METestImage.fptFile())
        try showFullTree()
        let panel = try panel()

        let waiting = try XCTUnwrap(
            descendants(of: panel, NSTextField.self)
                .first { $0.stringValue == "Analyzing the ME firmware…" },
            "the Full Tree tab waits with the same words: "
                + "\(descendants(of: panel, NSTextField.self).map(\.stringValue))")
        XCTAssertTrue(isOnScreen(waiting, under: panel),
                      "and shows them rather than an empty outline")
        XCTAssertTrue(
            descendants(of: panel, NSImageView.self).contains {
                isOnScreen($0, under: panel)
                    && $0.image?.accessibilityDescription == "Analyzing the ME firmware…"
            },
            "with the same symbol over them")
        XCTAssertEqual(try outline().numberOfRows, 0, "the premise: no tree yet")

        // The tree lands and takes the tab back.
        _ = try waitForDisplay(of: session())
        try showFullTree()
        XCTAssertGreaterThan(try outline().numberOfRows, 0, "the tree has rows now")
        XCTAssertFalse(isOnScreen(waiting, under: panel),
                       "and the wait has stepped aside")
    }

    /// An empty Summary tab is the whole panel while the ME region is read, so
    /// it says what is being waited for — with an icon over the words — rather
    /// than promising a summary in the same sentence it uses for a file that
    /// has none and for an analysis that failed.
    func testTheEmptyTabSaysWhatItIsWaitingFor() throws {
        _ = try openWithoutWaiting(METestImage.fptFile())
        let panel = try panel()

        let waiting = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(waiting.contains("Analyzing the ME firmware…"),
                      "the wait says what it is waiting for: \(waiting)")
        XCTAssertTrue(
            descendants(of: panel, NSImageView.self).contains {
                !$0.isHidden && $0.image?.accessibilityDescription == "Analyzing the ME firmware…"
            },
            "and wears a system symbol over the words")
        XCTAssertFalse(anyAmbiguousLayout(under: panel),
                       "the icon and its two lines have a size the engine can solve")

        // Once the analysis lands the panel is not still saying it is reading:
        // this file has firmware, so the summary itself takes the tab.
        _ = try waitForDisplay(of: session())
        let landed = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertFalse(landed.contains("Analyzing the ME firmware…"),
                       "a finished analysis is not still analyzing: \(landed)")
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

    /// The region's SHA-256/SHA-384/CRC-32 are three passes over the whole
    /// buffer for three rows, so the engine leaves them out of a parse. The row
    /// is still there, with placeholders, and looking at it is what asks.
    func testTheChecksumsRowFillsInWhenItIsLookedAt() throws {
        _ = try open(METestImage.fptFile())
        try showFullTree()
        let tree = try outline()

        let checksumsRow = try XCTUnwrap(row(ofTitle: "Checksums", in: tree))
        let session = try session()

        // Selecting the row is the request; the digests run off the main actor
        // and the row fills in when they land.
        let filled = try waitForDisplay(of: session) {
            tree.selectRowIndexes(IndexSet(integer: checksumsRow),
                                  byExtendingSelection: false)
        }
        XCTAssertNotNil(filled?.checksums?.crc32)

        // Spelled out rather than read off the curator: this is the panel's
        // own text, and the pure target is not linked here.
        let text = descendants(of: try panel(), NSTextField.self).map(\.stringValue)
        XCTAssertFalse(text.contains("Loading…"),
                       "the placeholders are gone once the numbers are in: \(text)")
        let crc = try XCTUnwrap(filled?.checksums?.crc32)
        XCTAssertTrue(text.contains(String(format: "0x%08X", crc)), "\(text)")
    }

    /// A value too long for the column wraps inside it rather than running off
    /// the side: a manifest's SHA-256 is 64 characters, and there is no
    /// sideways scroller to reach the rest of it with.
    func testALongValueWrapsInsideItsColumn() throws {
        _ = try open(METestImage.manifestFile())

        try showFullTree()
        let tree = try outline()
        let manifestRow = try XCTUnwrap(row(ofTitle: "Manifest", in: tree))
        tree.selectRowIndexes(IndexSet(integer: manifestRow), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let panel = try panel()
        let fields = descendants(of: panel, NSTextField.self)
        // The hash is the longest thing the detail shows.
        let hash = try XCTUnwrap(
            fields.first { $0.stringValue.count == 64
                && $0.stringValue.allSatisfy(\.isHexDigit) },
            "the manifest's SHA-256 is one of the rows: "
                + "\(fields.map(\.stringValue))"
        )
        let oneLine = ToolPanelFont.body().boundingRectForFont.height

        XCTAssertGreaterThan(hash.frame.height, oneLine,
                             "64 characters do not fit one line of this column")
        XCTAssertEqual(hash.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(hash.maximumNumberOfLines, 0)
        // And it stays inside the panel rather than reaching past its edge.
        let inPanel = hash.convert(hash.bounds, to: panel)
        XCTAssertLessThanOrEqual(inPanel.maxX, panel.bounds.maxX,
                                 "the value runs off the side of the panel")
    }

    /// The engine's field names run long, and the shared default column cut
    /// them off mid-word ("systemHeaderCRCVa…"). The name column takes the
    /// width its longest name needs — and when the panel is too narrow for
    /// that, it stops at half the list and the name wraps instead of being
    /// cut.
    func testTheNameColumnWidensForLongFieldNamesAndWrapsAtHalfTheList() throws {
        _ = try open(METestImage.manifestFile())

        try showFullTree()
        let tree = try outline()
        let manifestRow = try XCTUnwrap(row(ofTitle: "Manifest", in: tree))
        tree.selectRowIndexes(IndexSet(integer: manifestRow), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let names = try detailNameLabels()
        let longest = try XCTUnwrap(names.max { textWidth($0) < textWidth($1) },
                                    "the manifest's detail has named rows")
        let oneLine = ToolPanelFont.body().boundingRectForFont.height

        // Wide enough for it: the column took the room its longest name needs,
        // past the default it used to be pinned to, and every row shares that
        // one width so the values still line up.
        let widths = Set(names.map { $0.frame.width.rounded() })
        XCTAssertEqual(widths.count, 1, "one column for every row: \(widths)")
        let column = try XCTUnwrap(widths.first)
        XCTAssertGreaterThan(column, ToolPanelFont.detailLabelWidth,
                             "\"\(longest.stringValue)\" widened the column past the default")
        XCTAssertGreaterThanOrEqual(column, textWidth(longest),
                                    "\"\(longest.stringValue)\" is shown whole")
        XCTAssertLessThan(longest.frame.height, oneLine * 2,
                          "on one line — there is room for it")

        // Squeezed — the narrowest panel the split allows, zoomed to the
        // largest type the app offers — and the name no longer fits in half
        // the list. The column stops there and the name wraps.
        let controller = try XCTUnwrap(self.controller)
        controller.setToolPanelWidth(ToolController.minPanelWidth, animated: false)
        zoom(to: ToolPanelFont.sizeRange.upperBound)
        window?.layoutIfNeeded()

        let squeezed = try detailNameLabels()
        let widest = try XCTUnwrap(squeezed.first { $0.stringValue == longest.stringValue })
        let half = try detailContent().frame.width / 2
        let zoomedLine = ToolPanelFont.body().boundingRectForFont.height
        XCTAssertLessThan(half, textWidth(widest),
                          "the premise: half the list no longer holds the name")
        // Auto Layout sizes a text field's alignment rect, which is inset from
        // its frame by a point or two — so that is what the cap is read from.
        XCTAssertEqual(widest.alignmentRect(forFrame: widest.frame).width, half, accuracy: 1,
                       "the column stops at half the list")
        XCTAssertGreaterThan(widest.frame.height, zoomedLine,
                             "and the name wraps rather than being cut")
        XCTAssertEqual(widest.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(widest.maximumNumberOfLines, 0)
    }

    /// Zooms to `size` the way the View menu does.
    private func zoom(to size: CGFloat) {
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: size)
        window?.layoutIfNeeded()
    }

    /// The detail list's name column: the leading label of each row. Found by
    /// the row's shape — a horizontal pair of name and value — rather than by
    /// its colour, which the list's own placeholder shares.
    private func detailNameLabels() throws -> [NSTextField] {
        let panel = try panel()
        let scroll = try XCTUnwrap(
            descendants(of: panel, ToolDetailScroll.self).first { !$0.isHidden },
            "the detail list under the tree")
        return descendants(of: scroll, NSStackView.self)
            .filter { $0.orientation == .horizontal && $0.arrangedSubviews.count == 2 }
            .compactMap { $0.arrangedSubviews.first as? NSTextField }
    }

    private func detailContent() throws -> NSStackView {
        let panel = try panel()
        let scroll = try XCTUnwrap(
            descendants(of: panel, ToolDetailScroll.self).first { !$0.isHidden })
        return scroll.content
    }

    /// Whether `view` is actually shown: a view stays in the hierarchy — and in
    /// `descendants(of:)` — while it is hidden, and so does everything under a
    /// hidden ancestor, which is exactly how a tab switch works here.
    private func isOnScreen(_ view: NSView, under root: NSView) -> Bool {
        var here: NSView? = view
        while let step = here, step !== root.superview {
            if step.isHidden { return false }
            here = step.superview
        }
        return true
    }

    /// What a label's own text needs on one line, in the font it is drawn in.
    private func textWidth(_ label: NSTextField) -> CGFloat {
        label.attributedStringValue.size().width
    }

    /// A section that holds nothing reads grey in the tree's value column —
    /// it is a place in the layout, not something to go and look at — while
    /// its name stays as readable as any other row's.
    func testAnEmptySectionsValueIsGreyInTheTree() throws {
        _ = try open(METestImage.fptFileWithEmptyRegion())

        try showFullTree()
        let tree = try outline()
        let regionsRow = try XCTUnwrap(row(ofTitle: "Regions (FPT)", in: tree))
        tree.expandItem(tree.item(atRow: regionsRow))
        window?.layoutIfNeeded()

        func colours(row: Int) throws -> (name: NSColor?, value: NSColor?) {
            let name = try XCTUnwrap(
                tree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            let value = try XCTUnwrap(
                tree.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView)
            return (name.textField?.textColor, value.textField?.textColor)
        }

        let emptyRow = try XCTUnwrap(row(ofTitle: "FTUP", in: tree))
        XCTAssertEqual(subtitleText(tree, row: emptyRow), "0x3000 · Empty",
                       "the value says the section holds nothing")
        let empty = try colours(row: emptyRow)
        XCTAssertEqual(empty.value, .secondaryLabelColor)
        XCTAssertEqual(empty.name, .labelColor, "the row is still worth finding")

        // A region with bytes in it is drawn as before.
        let real = try colours(row: try XCTUnwrap(row(ofTitle: "FTUE", in: tree)))
        XCTAssertEqual(real.value, .labelColor)
        XCTAssertEqual(real.name, .labelColor)
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
        XCTAssertNotNil(restored, "coming back shows the analysis again")

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
        XCTAssertEqual(notice.textColor, SemanticColors.bad)
        let retry = try XCTUnwrap(
            descendants(of: panel, NSButton.self).first { $0.title == "Try Again" })
        XCTAssertFalse(retry.isHidden)

        // The empty tab above the line stops promising a summary and points at
        // the line that says why there is none.
        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("The analysis did not finish"), "\(text)")
        XCTAssertFalse(text.contains("Analyzing the ME firmware…"),
                       "the failure is not still a wait: \(text)")
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

    /// The same table with a third region that claims a place and no bytes —
    /// `FTUP` at 0x3000, size 0. What an image looks like where the layout
    /// leaves a slot unused.
    static func fptFileWithEmptyRegion() -> [UInt8] {
        var bytes = fptFile()
        u32(3, into: &bytes, at: 0x04)              // NumPartitions
        let ftup = 0x60
        for (index, byte) in "FTUP".utf8.enumerated() { bytes[ftup + index] = byte }
        u32(0x3000, into: &bytes, at: ftup + 0x08)  // Offset
        u32(0, into: &bytes, at: ftup + 0x0C)       // Size — none
        u32(0x01, into: &bytes, at: ftup + 0x1C)
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
