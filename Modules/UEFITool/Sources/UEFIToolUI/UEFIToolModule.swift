import AppKit
import ToolModuleKit
import UEFIContentSource
import UEFIImage
import UEFITool

/// The structure of a UEFI firmware image, read and shown
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// A bench opens a dump and wants to see what is in it — the volumes, the files
/// in them, the sections in those — and, for the one node it is looking at,
/// where it is and what its header says. It answers by reading, never by
/// assuming: the tree is the parser's, and the detail is the node's header read
/// back through the same reader.
public enum UEFIToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.uefi-structure"
    public static let title = "UEFI Structure"
    /// Three columns — name, type, subtype — and a list of label/value fields:
    /// the same room the FIT table takes, more than the minimap's 120.
    public static let preferredPanelWidth: CGFloat = 480

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        UEFIToolSession(host: host)
    }
}

/// What a parked session hands back: the node the user was looking at, and
/// nothing else. The parse is worth doing again — it is milliseconds — and a
/// tree of thousands of nodes per parked tool-module is how an app comes to
/// hold four copies of an image it is not showing (`ToolSession.parkedState`).
struct UEFIParkedState: ToolSessionState {
    var focus: NodeID?
}

/// What a parse hands back: the tree, and which checksums in it are wrong.
/// Read together off the main actor, because the checksum pass reads every file
/// body and must never run on show or in a table callback.
private struct ParseResult: Sendable {
    let image: UEFIImage
    let badChecksums: [NodeID: Set<UEFIChecksumField>]
}

/// The running instrument: parse off the main actor, show the tree, publish the
/// one zone for the node in focus, and say what that node is.
@MainActor public final class UEFIToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = UEFIToolViewController()

    /// The parsed image and the reader over the snapshot it was parsed from.
    /// Kept together: the detail reads headers through the same bytes the tree
    /// came from, so the two cannot drift apart.
    private var image: UEFIImage?
    private var reader: ImageReader?
    /// Which nodes' checksums the last parse found wrong, keyed by node id.
    /// Readable from outside so the app's tests can assert on it without
    /// reaching into a view.
    public private(set) var checksumProblems: [NodeID: Set<UEFIChecksumField>] = [:]
    /// The node the user is looking at. Nil before a choice, and after a
    /// re-parse that lost it.
    private var focus: NodeID?
    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0
    /// The GUID catalogue the tree names are read from: empty until a fresh
    /// download lands, which then names the GUIDs for the rest of the session.
    /// A node with a GUID shows the GUID itself in the meantime.
    private var guids: GuidsCatalogue = .empty
    /// Which catalogue download is the current one, so a slow one does not
    /// overwrite a fresh one.
    private var guidsGeneration = 0
    /// Whether the line under the tree is an answer to something the user asked
    /// for — a fix that wrote, or a refusal. Such a line survives the re-read
    /// its own write caused and is wiped by the next re-read that is not its
    /// own (the check in `reparse()`).
    private var noticeAnswersTheUser = false

    /// Where the fresh catalogue comes from. A test installs its own so the
    /// suite does not reach GitHub.
    static var guidsSource: any GuidsSource = LongSoftGuidsRepository()

    /// Called on the main actor once a parse has landed and the panel has been
    /// shown. The parse runs off the main actor, so a test that waited for it
    /// on the clock would be a test that fails on a busy machine.
    public var onDisplay: ((UEFIImage?) -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] nodeID in self?.select(nodeID) }
        controller.onSelectTop = { [weak self] in self?.showTopNode() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        reparse()
        refreshGuids()
    }

    /// Any change is a reason to read again. The tree is cheap to rebuild and
    /// expensive to keep in sync, so a re-parse is the honest answer to every
    /// edit — and the selection is kept by path, so it survives a re-parse of
    /// the same image and is dropped when the node is gone.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {}

    public var parkedState: (any ToolSessionState)? { UEFIParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? UEFIParkedState else { return }
        focus = state.focus
    }

    // MARK: - Reading

    private func reparse() {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            image = nil
            reader = nil
            checksumProblems = [:]
            controller.say("Could not read the file: \(error)", asProblem: true)
            show()
            return
        }

        let source = ToolContentByteSource(reader: snapshot)
        generation += 1
        let generation = self.generation
        // The parse is running: the line under the tree says so, next to the
        // bar. The successful parse clears it in the block below, so the line
        // is only ever the reading it is still doing — except when the line is
        // an answer to something the user asked for, which survives the re-read
        // its own write caused (the noticeAnswersTheUser flag below).
        if !noticeAnswersTheUser {
            controller.say("Reading…")
        }
        controller.showBusy()
        let reporter = progressReporter()
        Task { [weak self] in
            let parsed = await UEFIToolSession.parse(source, progress: reporter)
            guard let self, self.generation == generation else { return }
            self.image = parsed.image
            self.checksumProblems = parsed.badChecksums
            self.reader = ImageReader(source)
            self.controller.endBusy()
            if self.noticeAnswersTheUser {
                self.noticeAnswersTheUser = false
            } else {
                self.controller.say("")
            }
            self.show()
            self.onDisplay?(self.image)
        }
    }

    /// The catalogue download: in the background, so it never blocks the parse
    /// or the UI. On success it improves the names for the rest of the session
    /// and re-shows the tree with them; on failure the baseline the build ships
    /// stays, and the tree keeps the names it already shows. A download failure
    /// is not a problem worth saying in red — the names are still there, just
    /// older.
    private func refreshGuids() {
        guidsGeneration += 1
        let generation = guidsGeneration
        Task { [weak self] in
            do {
                let fresh = try await Self.guidsSource.guids()
                guard let self, self.guidsGeneration == generation else { return }
                self.guids = fresh
                self.show()
            } catch {
                // The baseline stays. Nothing to say: the tree is not wrong, it
                // is just not as up to date as it could be.
            }
        }
    }

    /// What a parse reports through: a hop back to the main actor that lands on
    /// the module's own bottom-row bar. Built per parse, so the detached task
    /// only ever moves the bar of the parse it ran.
    private func progressReporter() -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.controller.updateProgress(fraction) }
        }
    }

    /// Off the main actor: a 16 MiB image is a full UEFI parse, and the panel
    /// is on screen while it runs. The checksum pass is part of the same task —
    /// it reads every file body, so it too must never run on show or in a table
    /// callback.
    private nonisolated static func parse(
        _ source: any ByteSource,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> ParseResult {
        await Task.detached(priority: .userInitiated) {
            let image = UEFIParser.parse(source, progress: progress)
            let badChecksums = UEFIChecksumCheck.badFields(
                in: image, reader: ImageReader(source)
            )
            return ParseResult(image: image, badChecksums: badChecksums)
        }.value
    }

    /// Everything the panel shows, in one call: the tree, the detail for the
    /// node in focus, and the one zone that node publishes.
    private func show() {
        guard let image, let reader else {
            controller.show(
                image: nil, focus: nil, detail: .empty, catalogue: guids,
                badChecksums: checksumProblems, canWrite: !host.isReadOnly
            )
            host.publish(.empty)
            return
        }
        let node = focus.flatMap { image.node($0) }
        let detail = node.map {
            UEFIDetail.build(
                for: $0, image: image, reader: reader,
                badFields: checksumProblems[$0.id] ?? []
            )
        } ?? .empty
        controller.show(
            image: image, focus: focus, detail: detail, catalogue: guids,
            badChecksums: checksumProblems, canWrite: !host.isReadOnly
        )
        host.publish(UEFIPresenter.zones(for: node))
    }

    // MARK: - What the panel asks for

    /// The user picked a node in the tree. Publishing again is what moves the
    /// outline in the dump, and the host brings a newly focused zone on screen
    /// by itself.
    private func select(_ nodeID: NodeID?) {
        focus = nodeID
        show()
    }

    /// The title names the image, not a row: the one root the tree folded into
    /// it is selected by a click exactly as its row would — its zone, its
    /// detail. A file with nothing folded into the title — one with several
    /// roots, or a single leaf — has nothing to select, so it does nothing
    /// rather than clear a focus the user set.
    ///
    /// Public because a click on the title is driven the same way the panel's
    /// other clicks are — through the session, not a simulated mouse.
    public func showTopNode() {
        guard let image, let title = UEFITreeDisplay.present(image).title else { return }
        focus = title.id
        show()
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the node it stands for to the front —
    /// expand the tree to it and select it, which is the half only this side
    /// knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        guard let nodeID = UEFIPresenter.nodeID(ofZone: id) else { return }
        focus = nodeID
        show()
    }

    // MARK: - Fix Checksum

    /// Recompute a node's checksum and write the corrected bytes as one
    /// undoable step. A read-only file refuses; otherwise the node's current
    /// bytes are re-read off the main actor — it may have moved since the parse
    /// that flagged it — and whatever still differs is applied, ⌘Z taking it
    /// back. The write's own re-parse clears the red flag and the icon on their
    /// own, so the "written" line survives exactly that one re-read.
    ///
    /// Public because a right-click cannot be simulated — this is the level the
    /// app's tests drive, the same way FIT's `fixChecksum()` is.
    public func fixChecksum(for nodeID: NodeID) {
        guard !host.isReadOnly else {
            fail("This file is open read-only.")
            return
        }
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            fail("Could not read the file: \(error)")
            return
        }
        controller.showBusy()
        let reporter = progressReporter()
        Task { [weak self] in
            let repairs = await UEFIToolSession.prepareChecksumFix(
                nodeID, snapshot: snapshot, progress: reporter
            )
            guard let self else { return }
            self.controller.endBusy()
            guard let repairs, !repairs.isEmpty else {
                // Nothing to write: the node is gone, or its checksum already
                // checks out — the flag the click answered was a stale one.
                return
            }
            let transaction = ToolTransaction(
                name: "Fix Checksum",
                writes: repairs.map {
                    ToolTransaction.Write(offset: $0.offset, bytes: $0.bytes)
                }
            )
            do {
                try self.host.apply(transaction)
                self.noticeAnswersTheUser = true
                self.controller.say("Checksum written. ⌘Z takes it back.")
            } catch {
                self.fail("Could not write: \(error)")
            }
        }
    }

    /// Re-read the snapshot off the main actor and return the writes that put
    /// nodeID's checksum right, or nil when the parse no longer finds the node
    /// or the checksum already checks out.
    private nonisolated static func prepareChecksumFix(
        _ nodeID: NodeID,
        snapshot: any ToolContentReader,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [ChecksumRepair]? {
        await Task.detached(priority: .userInitiated) {
            let source = ToolContentByteSource(reader: snapshot)
            let image = UEFIParser.parse(source, progress: progress)
            guard let node = image.node(nodeID) else { return nil }
            let revision = UEFIChecksumCheck.volumeRevision(of: node, in: image)
            let repairs = UEFIChecksumCheck.repairs(
                for: node, volumeRevision: revision, in: ImageReader(source)
            )
            return repairs.isEmpty ? nil : repairs
        }.value
    }

    /// Something the user asked for did not happen, said in red. It survives
    /// the re-read that could otherwise wipe it, exactly like the success note.
    private func fail(_ text: String) {
        noticeAnswersTheUser = true
        controller.say(text, asProblem: true)
    }
}
