import AppKit
import MEFirmware
import MEATool
import ToolModuleKit
import UEFIImage

/// The "ME Analyzer" instrument: run `MEFirmware`'s analysis over the open
/// file and show the result — on the first tab the MEA-style summary, on the
/// second the full structure the module decoded
/// (`Design/ME_ANALYZER_PANEL.md`).
///
/// The panel is a reader, never a writer: it shows what the engine found and
/// never edits the file, so there is no Fix/repair half to it. The analysis is
/// automatic — every show of the panel and every change of the content re-parses
/// — and each parse runs off the main actor behind an indeterminate bar, because
/// `MEFirmwareAnalyzer.analyze` reports no fractions of its own.
public enum MEAToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.me-analyzer"
    public static let title = "ME Analyzer"
    /// Two columns — a name and a compact second line (range/count) — plus the
    /// detail list below: the same room the UEFI tree takes.
    public static let preferredPanelWidth: CGFloat = 480

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        MEAToolSession(host: host)
    }
}

/// What a parked session hands back: the tab the user was on and the tree row
/// they were looking at. The analysis is worth doing again — it is the module's
/// whole job, and it is automatic — so only the two choices are kept
/// (`ToolSession.parkedState`).
struct MEAParkedState: ToolSessionState {
    var tabIndex: Int
    var focusPath: [Int]?
}

/// The running instrument: read the file off the main actor, run the engine's
/// analysis in the background, show the curated tree, publish the one zone for
/// the row in focus, and keep nothing else.
@MainActor public final class MEAToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = MEAToolViewController()
    /// The one engine instance this session keeps: `MEFirmwareAnalyzer` holds
    /// the data source, whose in-memory single-flight cache of MEA.dat is what
    /// makes re-reading the same dump cheap.
    private let analyzer: MEFirmwareAnalyzer

    /// The presented tree of the last successful analysis — the outline's data.
    private var roots: [MEANode] = []

    /// Listening for a newer `MEA.dat`. Cancelled in `stop()`.
    private var databaseWatch: Task<Void, Never>?
    /// The analysis those roots were built from, kept so the one group the
    /// engine does not fill — the region's checksums — can be added to it
    /// later without a re-parse.
    private var analysis: FirmwareAnalysis?
    /// The in-flight checksum request, so selecting the row twice asks once.
    private var checksumsTask: Task<Void, Never>?
    /// The user's selection as a tree path. Nil before a choice, and after a
    /// re-parse that lost the row.
    private var focusPath: [Int]?
    /// Which tab the panel is on (0 = Summary, 1 = Full Tree).
    private var tabIndex = 0
    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0

    /// Where the fresh firmware database comes from. A test installs its own so
    /// the suite does not reach GitHub — the same public seam as
    /// `FITToolSession.microcodeSource`, for the app-suite tests that live in
    /// another module and drive the session end to end.
    public static var dataSource: any MEADataSource = MEAGitHubDataRepository()

    /// Called on the main actor once a parse has landed and the panel has been
    /// shown. The analysis runs off the main actor, so a test that waited for it
    /// on the clock would be a test that fails on a busy machine.
    public var onDisplay: ((FirmwareAnalysis?) -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        analyzer = MEFirmwareAnalyzer(data: Self.dataSource)
        controller.onSelect = { [weak self] path in self?.select(path) }
        controller.onTabChanged = { [weak self] tab in self?.selectTab(tab) }
        controller.onRetry = { [weak self] in self?.reparse() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        watchTheDatabase()
        reparse()
    }

    /// `MEA.dat` is re-checked once a day, behind whatever is being read at the
    /// time — so an analysis can be finished against a database that has since
    /// been superseded. When a newer one lands, the reading is done again
    /// against it: the identification, the SKU, the known-bad hashes all come
    /// out of that file, and an answer from last week's copy is exactly what
    /// the check was for.
    private func watchTheDatabase() {
        guard databaseWatch == nil else { return }
        let source = Self.dataSource
        databaseWatch = Task { [weak self] in
            for await _ in await source.databaseChanges() {
                guard let self else { return }
                // The pane's cached analysis was read against the database that
                // has just been replaced, so it is the first thing that is out
                // of date — and `reparse()` would otherwise present it.
                self.analysisProvider?.setCachedMEAnalysis(nil, meRegion: nil)
                self.reparse()
            }
        }
    }

    /// Any change is a reason to read again. The analysis is cheap to rebuild
    /// and expensive to keep in sync, so a re-parse is the honest answer to
    /// every edit — and the selection is kept by path, so it survives a
    /// re-parse of the same file and is dropped when the row is gone.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {
        databaseWatch?.cancel()
        databaseWatch = nil
    }

    public var parkedState: (any ToolSessionState)? {
        MEAParkedState(tabIndex: tabIndex, focusPath: focusPath)
    }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? MEAParkedState else { return }
        tabIndex = state.tabIndex
        focusPath = state.focusPath
    }

    // MARK: - Reading

    /// The last analysis's own cache and the tool's shared UEFI tree, reached
    /// through the host: neither is on the base `ToolHost` seam (which stays
    /// format-agnostic), so a tool-module that wants them casts for it, the
    /// same way it would ask for anything else beyond the seam's base
    /// contract. Nil under a host that offers neither (a test double) — the
    /// module falls back to its original, self-contained behavior.
    private var treeProvider: (any UEFITreeProviding)? { host as? any UEFITreeProviding }
    private var analysisProvider: (any MEAAnalysisProviding)? { host as? any MEAAnalysisProviding }

    private func reparse() {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            roots = []
            focusPath = nil
            controller.showSummary([])
            controller.setPlaceholder(.failed)
            controller.say("Could not read the file: \(error)", asProblem: true)
            show()
            return
        }

        // The shared tree already knows the ME region's bounds from the
        // descriptor — a cheap lookup, not a scan — whether or not the UEFI
        // tool-module has ever been opened on this file. Handing it to the
        // engine replaces MEFirmware's own whole-file `$FPT` search with a
        // read of just those bytes.
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let analysisProvider = self.analysisProvider

        // A cached analysis survives a panel switch untouched: the pane's
        // holder only drops it when an edit actually lands inside the ME
        // region (`PaneUEFIState.invalidate`), so reactivating this
        // tool-module after using another one is instant rather than a
        // second full analysis of data nothing changed.
        if let cached = analysisProvider?.cachedMEAnalysis() {
            present(cached)
            // Announced on the next turn rather than from inside this call: a
            // caller that has only just asked for this session — `start()` runs
            // during activation — has had no chance to listen yet, and a cached
            // analysis would otherwise be the one reading it never hears about.
            Task { @MainActor [weak self] in self?.onDisplay?(cached) }
            return
        }

        generation += 1
        let generation = self.generation
        // Whatever the last analysis was, and whatever was being computed for
        // it, belongs to bytes that are no longer the ones on screen.
        checksumsTask?.cancel()
        checksumsTask = nil
        analysis = nil
        // Named, not just "Reading…": three panels can be the one on screen and
        // each reads something different, so the line says which this is.
        controller.say("Reading ME…")
        // The empty tab is the whole panel until the analysis lands, so it says
        // what is being waited for rather than promising a summary.
        controller.setPlaceholder(.waiting)
        controller.showBusy()
        let analyzer = self.analyzer
        Task { [weak self] in
            let result = await MEAToolSession.analyze(snapshot, analyzer: analyzer, meRegion: meRegion)
            guard let self, self.generation == generation else { return }
            self.controller.endBusy()
            switch result {
            case .success(let analysis):
                // The reading is over — the line returns to empty, as the other
                // panels' do after a successful parse.
                self.controller.say("")
                analysisProvider?.setCachedMEAnalysis(analysis, meRegion: meRegion)
                self.present(analysis)
                self.onDisplay?(analysis)
            case .failure(let error):
                self.roots = []
                self.focusPath = nil
                self.controller.showSummary([])
                self.controller.setPlaceholder(.failed)
                self.controller.say(
                    MEAToolSession.describe(error), asProblem: true)
                self.controller.showRetry(true)
                self.show()
                self.onDisplay?(nil)
            }
        }
    }

    /// Off the main actor: materialise just the ME region (when the shared
    /// tree could resolve it) and hand it to the engine at that region's own
    /// base offset, so every address the engine reports is still absolute in
    /// the open file. Falls back to the whole file — exactly today's
    /// behavior, `baseOffset 0` — when the region is not known (no
    /// descriptor recognized yet, or a bare ME dump with no descriptor at
    /// all): MEFirmware's own `$FPT` search over the whole buffer is what
    /// covers that case, unchanged.
    private nonisolated static func analyze(
        _ snapshot: any ToolContentReader,
        analyzer: MEFirmwareAnalyzer,
        meRegion: Range<UInt64>?
    ) async -> Result<FirmwareAnalysis, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let data = try MEAToolSession.regionBytes(snapshot, meRegion)
                let baseOffset = MEAToolSession.regionBase(meRegion)
                let analysis = try await analyzer.analyze(region: data, baseOffset: baseOffset)
                return .success(analysis)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// The bytes handed to the engine: the ME region when the shared tree could
    /// resolve it, the whole file otherwise. Both the parse and the later
    /// checksum request go through here, so the digests describe the same
    /// buffer the analysis was made from and not a differently chosen one.
    private nonisolated static func regionBytes(
        _ snapshot: any ToolContentReader,
        _ meRegion: Range<UInt64>?
    ) throws -> Data {
        if let meRegion, meRegion.lowerBound < meRegion.upperBound {
            return try readRange(snapshot, meRegion)
        }
        return try readAll(snapshot)
    }

    /// Where `regionBytes` starts in the open file.
    private nonisolated static func regionBase(_ meRegion: Range<UInt64>?) -> Int {
        guard let meRegion, meRegion.lowerBound < meRegion.upperBound else { return 0 }
        return Int(meRegion.lowerBound)
    }

    /// The whole content, as one `Data`. The engine takes a region buffer, so
    /// the reader is materialised; chunked so a large image is never assembled
    /// in one giant append.
    private nonisolated static func readAll(
        _ snapshot: any ToolContentReader
    ) throws -> Data {
        try readRange(snapshot, 0..<snapshot.size)
    }

    /// `range`, as one `Data` — the same chunked-read shape as `readAll`,
    /// narrowed to just the bytes the engine actually needs.
    private nonisolated static func readRange(
        _ snapshot: any ToolContentReader, _ range: Range<UInt64>
    ) throws -> Data {
        var data = Data()
        let chunk = 1 << 20
        var offset = range.lowerBound
        while offset < range.upperBound {
            let length = Int(min(UInt64(chunk), range.upperBound - offset))
            data.append(contentsOf: try snapshot.read(at: offset, length: length))
            offset += UInt64(length)
        }
        return data
    }

    /// A data error's line for the status row. The engine's `MEADataError` is a
    /// `LocalizedError` with its own wording; anything else is an internal
    /// failure worth saying plainly.
    private nonisolated static func describe(_ error: Error) -> String {
        (error as? MEADataError)?.errorDescription
            ?? "The analysis failed: \(error.localizedDescription)"
    }

    /// A successful analysis lands here: present the summary and the curated
    /// tree and show them, keeping whatever selection still resolves after the
    /// re-parse.
    private func present(_ analysis: FirmwareAnalysis) {
        self.analysis = analysis
        roots = MEACurator.present(analysis)
        if let path = focusPath, MEATree.node(at: path, in: roots) == nil {
            focusPath = nil
        }
        controller.showRetry(false)
        // An analysis has landed — fresh or out of the cache — so nothing is
        // being waited for. If the summary is still empty it is because this
        // file has no ME firmware, which is what the empty tab now says.
        controller.setPlaceholder(.empty)
        controller.showSummary(MEASummary.build(analysis))
        show()
    }

    /// Everything the panel shows, in one call.
    private func show() {
        let focus = focusPath.flatMap { MEATree.node(at: $0, in: roots) }
        controller.show(roots: roots, focusPath: focusPath, tab: tabIndex)
        host.publish(focus.map(MEAZones.build) ?? .empty)
    }

    // MARK: - What the panel asks for

    /// The user picked a row in the tree. Revealing is what moves the outline in
    /// the dump: a row that stands for bytes scrolls the dump to them.
    private func select(_ path: [Int]?) {
        focusPath = path
        if let node = path.flatMap({ MEATree.node(at: $0, in: roots) }),
           let range = node.range {
            host.reveal(range, select: false)
        }
        show()
        // Looking at the checksums row is what asks for the checksums: the
        // engine leaves them out of a parse because they are three passes over
        // the whole region, and until now nothing was going to read them.
        if let path, path == MEACurator.checksumsPath(in: roots) {
            loadChecksums()
        }
    }

    /// Compute the region's digests off the main actor and put them into the
    /// analysis the panel is showing. The bytes are read again rather than kept
    /// alive between parses — this path runs once per file, if at all, and a
    /// retained region would cost every open dump the memory for a row most
    /// readers never open.
    private func loadChecksums() {
        guard let analysis, analysis.checksums == nil, checksumsTask == nil,
              let snapshot = try? host.snapshot() else { return }
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let analysisProvider = self.analysisProvider
        let generation = self.generation
        checksumsTask = Task { [weak self] in
            let checksums = await MEAToolSession.checksums(snapshot, meRegion: meRegion)
            guard let self, self.generation == generation else { return }
            self.checksumsTask = nil
            guard var updated = self.analysis, updated.checksums == nil else { return }
            updated.checksums = checksums
            analysisProvider?.setCachedMEAnalysis(updated, meRegion: meRegion)
            // Re-presenting rebuilds the rows from the fuller analysis; the
            // selection is kept by path, so the row the reader is looking at
            // stays where it is and simply fills in.
            self.present(updated)
            // The panel is showing this analysis, which is what `onDisplay`
            // means — and it is the seam a test waits on instead of the clock.
            self.onDisplay?(updated)
        }
    }

    /// Off the main actor: the same region `analyze` was given, digested.
    /// An unreadable file leaves every field nil, and the group then goes —
    /// the panel does not stand there promising numbers it cannot get.
    private nonisolated static func checksums(
        _ snapshot: any ToolContentReader,
        meRegion: Range<UInt64>?
    ) async -> MEFirmware.Checksums {
        // `Checksums` is spelled out: UEFIImage has one of its own, and this
        // file can see both.
        await Task.detached(priority: .userInitiated) {
            guard let data = try? MEAToolSession.regionBytes(snapshot, meRegion) else {
                return MEFirmware.Checksums()
            }
            return await MEFirmwareAnalyzer.checksums(of: data)
        }.value
    }

    /// The user changed tab. Purely a choice of what to look at — the analysis
    /// is independent of it — but it is what a parked session hands back.
    private func selectTab(_ tab: Int) {
        tabIndex = tab
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the row it stands for to the front —
    /// which is the half only this side knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        let path = id.split(separator: "/").compactMap { Int($0) }
        guard !path.isEmpty, MEATree.node(at: path, in: roots) != nil else { return }
        focusPath = path
        show()
    }
}
