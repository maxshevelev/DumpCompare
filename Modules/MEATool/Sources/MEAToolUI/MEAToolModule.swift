import AppKit
import MEFirmware
import MEATool
import ToolModuleKit

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
        reparse()
    }

    /// Any change is a reason to read again. The analysis is cheap to rebuild
    /// and expensive to keep in sync, so a re-parse is the honest answer to
    /// every edit — and the selection is kept by path, so it survives a
    /// re-parse of the same file and is dropped when the row is gone.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {}

    public var parkedState: (any ToolSessionState)? {
        MEAParkedState(tabIndex: tabIndex, focusPath: focusPath)
    }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? MEAParkedState else { return }
        tabIndex = state.tabIndex
        focusPath = state.focusPath
    }

    // MARK: - Reading

    private func reparse() {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            roots = []
            focusPath = nil
            controller.showSummary([])
            controller.say("Could not read the file: \(error)", asProblem: true)
            show()
            return
        }

        generation += 1
        let generation = self.generation
        controller.say("Reading…")
        controller.showBusy()
        let analyzer = self.analyzer
        Task { [weak self] in
            let result = await MEAToolSession.analyze(snapshot, analyzer: analyzer)
            guard let self, self.generation == generation else { return }
            self.controller.endBusy()
            switch result {
            case .success(let analysis):
                // The reading is over — the line returns to empty, as the other
                // panels' do after a successful parse.
                self.controller.say("")
                self.present(analysis)
                self.onDisplay?(analysis)
            case .failure(let error):
                self.roots = []
                self.focusPath = nil
                self.controller.showSummary([])
                self.controller.say(
                    MEAToolSession.describe(error), asProblem: true)
                self.controller.showRetry(true)
                self.show()
                self.onDisplay?(nil)
            }
        }
    }

    /// Off the main actor: materialise the file and hand it to the engine as
    /// one region (`baseOffset 0`, so every reported offset is already absolute
    /// in the open file — the thing the panel reveals and zones).
    private nonisolated static func analyze(
        _ snapshot: any ToolContentReader,
        analyzer: MEFirmwareAnalyzer
    ) async -> Result<FirmwareAnalysis, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let data = try MEAToolSession.readAll(snapshot)
                let analysis = try await analyzer.analyze(region: data)
                return .success(analysis)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// The whole content, as one `Data`. The engine takes a region buffer, so
    /// the reader is materialised; chunked so a large image is never assembled
    /// in one giant append.
    private nonisolated static func readAll(
        _ snapshot: any ToolContentReader
    ) throws -> Data {
        var data = Data()
        let chunk = 1 << 20
        var offset: UInt64 = 0
        while offset < snapshot.size {
            let length = Int(min(UInt64(chunk), snapshot.size - offset))
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
        roots = MEACurator.present(analysis)
        if let path = focusPath, MEATree.node(at: path, in: roots) == nil {
            focusPath = nil
        }
        controller.showRetry(false)
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
