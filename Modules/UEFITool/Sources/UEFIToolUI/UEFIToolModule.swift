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

    /// How long a branch may take to be read before the row waiting on it says
    /// "Loading…". Under this the row simply opens when it is ready, and no
    /// placeholder is drawn at all — which is what keeps a fast branch from
    /// costing two animations over the same rows.
    ///
    /// Settable so a test can take the timing out of the picture and drive the
    /// slow path on demand.
    @MainActor public static var loadingRowDelay: TimeInterval = 0.2

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        UEFIToolSession(host: host)
    }
}

/// What a parked session hands back: the node the user was looking at, and
/// nothing else. The tree itself is the pane's, not the session's — parking
/// costs it nothing and reactivating finds it exactly as it was left
/// (`ToolSession.parkedState`).
struct UEFIParkedState: ToolSessionState {
    var focus: NodeID?
}

/// What one checksum pass hands back: for every node it read, the fields that
/// are wrong and the writes that would put them right — read together off the
/// main actor, because a pass reads every file body it covers and must never
/// run on show or in a table callback. The repairs are the half that makes a
/// wrong field say what it should be; the fields are the half the warning and
/// the icon key on.
///
/// A pass covers only the nodes that have just been materialized, never the
/// whole image: the tree grows a branch at a time, and each branch is read
/// once, as it appears.
private struct ChecksumPass: Sendable {
    let nodeRepairs: [NodeID: [ChecksumRepair]]
    let badChecksums: [NodeID: Set<UEFIChecksumField>]
}

/// The running instrument: read the pane's shared tree, show it, publish the
/// one zone for the node in focus, and say what that node is.
///
/// It never parses the image. Opening the panel yields the top level; a row
/// the reader opens materializes that one branch, off the main actor, with a
/// "Loading…" row in its place while it does; the address mapping is one
/// descent to the last node. Everything it materializes stays in the pane's
/// tree, so the next tool-module to want the same branch finds it open.
@MainActor public final class UEFIToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = UEFIToolViewController()

    /// The pane's one shared lazy tree — everything this panel shows is read
    /// through it: the outline's rows, the summary line, the detail's fields,
    /// and the mapping the Address row needs. Kept across every `show()`, and
    /// across every activation of this tool-module, so a panel switch costs
    /// nothing: whatever an earlier session (or MEA, or FIT) already opened is
    /// still open.
    private var tree: LazyUEFITree?
    /// Our subscription to that tree, so a branch someone else materialized
    /// reaches this panel's rows and its checksum pass too.
    private var observation: LazyUEFITree.ObserverToken?
    /// The tree this session built for itself, under a host that offers none —
    /// a test double. Dropped whenever the content changes, since it is over a
    /// frozen snapshot rather than the live file.
    private var ownTree: LazyUEFITree?

    /// Which nodes' checksums have been read so far, so each branch is read
    /// once as it appears rather than the whole image over again every time
    /// one more branch does.
    private var checkedIDs: Set<NodeID> = []
    /// How many checksum passes are running, and who is waiting for the last
    /// of them to land — what makes "the panel is showing this file" mean the
    /// flags on it are settled.
    private var checksumPassesInFlight = 0
    private var checksumWaiters: [() -> Void] = []
    /// Whether the mapping has been asked for since the last edit, so a second
    /// selection does not start a second descent to the Volume Top File.
    private var askedForAddresses = false
    /// Which nodes' checksums were found wrong, keyed by node id. Readable
    /// from outside so the app's tests can assert on it without reaching into
    /// a view.
    public private(set) var checksumProblems: [NodeID: Set<UEFIChecksumField>] = [:]
    /// The same passes' repairs, keyed by node id — what a wrong field should
    /// read, carried so the detail can quote it without re-reading the body.
    private var nodeRepairs: [NodeID: [ChecksumRepair]] = [:]
    /// The node the user is looking at. Nil before a choice, and after an edit
    /// that lost it.
    private var focus: NodeID?
    /// Which reading of the file is the current one. A file edited twice in
    /// quick succession has checksum passes in flight against both, and the
    /// one that finishes second is not necessarily the one that read the newer
    /// bytes.
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
    /// own (the check in `bind()`).
    private var noticeAnswersTheUser = false

    /// Where the fresh catalogue comes from. A test installs its own so the
    /// suite does not reach GitHub.
    static var guidsSource: any GuidsSource = LongSoftGuidsRepository()

    /// Called on the main actor once the tree's top level is there and the
    /// panel has been shown. The build runs off the main actor, so a test that
    /// waited for it on the clock would be a test that fails on a busy
    /// machine. The image it is handed is the tree as materialized so far —
    /// the top level, plus whatever anything has since opened.
    public var onDisplay: ((UEFIImage?) -> Void)?

    /// Called on the main actor each time a checksum pass has landed and its
    /// findings are on screen. A branch's checksums are read after the branch
    /// itself arrives, so this is the seam a test waits on when what it is
    /// about is a flag rather than a row.
    public var onChecksums: (() -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] nodeID in self?.select(nodeID) }
        controller.onSelectTop = { [weak self] in self?.showTopNode() }
        controller.onRevealAtCaret = { [weak self] in self?.revealNodeAtCaret() }
        controller.onFixChecksum = { [weak self] nodeID in
            self?.fixChecksum(for: nodeID)
        }
        controller.onOpenRowsChanged = { [weak self] in self?.rememberOpenRows() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        bind()
        refreshGuids()
    }

    /// Any change is a reason to read again — but not to read the file again.
    /// The pane's tree has already been told which of its branches the edit
    /// made stale (`PaneUEFIState.invalidate`), so all this has to do is show
    /// what is left and let the reader re-open whatever they want back. The
    /// selection is kept by path, so it survives an edit that left its node
    /// where it was and is dropped when the node is gone.
    public func contentChanged(_ change: ToolContentChange) {
        // A tree of our own is over a frozen snapshot and cannot be told about
        // an edit; the shared one can, and was.
        ownTree = nil
        bind()
    }

    public func stop() {
        if let tree, let observation { tree.removeObserver(observation) }
        observation = nil
    }

    public var parkedState: (any ToolSessionState)? { UEFIParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? UEFIParkedState else { return }
        focus = state.focus
    }

    // MARK: - Reading

    /// The seam a UEFI-aware tool-module reaches through for the pane's one
    /// shared tree — the same protocol `MEATool` casts `host` for, defined in
    /// `UEFIImage` so neither side has to depend on the other or on the app.
    private var treeProvider: (any UEFITreeProviding)? { host as? any UEFITreeProviding }

    /// Points this session at the tree it should be reading, subscribes to it,
    /// and shows what it has.
    ///
    /// Nothing here parses. The shared tree is fetched — built, if this is the
    /// first thing to ask for it — and everything after that is on demand:
    /// the outline asks for a branch when a row is opened, the checksum pass
    /// reads a branch when one appears, and the mapping is worked out by
    /// walking to the last node rather than through the whole image. Opening
    /// this panel on a file another tool-module has already looked at costs
    /// one `show()`.
    private func bind() {
        // Re-subscribed unconditionally, even to the tree already in hand: a
        // session that was stopped and started again — parked and brought back
        // — dropped its subscription on the way out.
        if let tree, let observation { tree.removeObserver(observation) }
        observation = nil
        tree = currentTree()
        observation = tree?.addObserver { [weak self] change in
            self?.treeChanged(change)
        }

        generation += 1
        checkedIDs = []
        nodeRepairs = [:]
        checksumProblems = [:]

        guard let tree else {
            controller.endBusy()
            controller.say("Could not read the file.", asProblem: true)
            show(publish: true)
            return
        }

        // Only the top level of a chip dump with no descriptor costs a wait —
        // it is a signature scan of the whole file, and until it lands there
        // is nothing to draw. An Intel image is there before the bar is drawn.
        if !tree.isReady, !noticeAnswersTheUser {
            controller.say("Reading…")
            controller.showBusy()
        }
        show(publish: true, rowsChanged: true)

        tree.whenReady { [weak self] in
            guard let self, self.tree === tree else { return }
            self.controller.endBusy()
            if self.noticeAnswersTheUser {
                self.noticeAnswersTheUser = false
            } else {
                self.controller.say("")
            }
            // What the reader had open on this file, put back before anything
            // is announced — coming back to a panel and finding the tree shut
            // is coming back to a panel that forgot.
            self.controller.restoreOpenRows(self.treeProvider?.openUEFIRows() ?? [])
            // `onDisplay` means "the panel is showing this file": the top
            // level, and its own checksums read. A branch opened later brings
            // its own pass, announced through `onChecksums`.
            self.verifyNewChecksums {
                self.show(publish: true, rowsChanged: true)
                self.onDisplay?(self.currentImage)
            }
        }
    }

    /// The tree to read: the pane's shared one, or — under a host that offers
    /// none, which in practice means a test double — one of our own over a
    /// frozen snapshot, kept until the content changes.
    private func currentTree() -> LazyUEFITree? {
        if let shared = treeProvider?.uefiTree() { return shared }
        if let ownTree { return ownTree }
        guard let snapshot = try? host.snapshot() else { return nil }
        let tree = LazyUEFITree(ToolContentByteSource(reader: snapshot))
        ownTree = tree
        return tree
    }

    /// The tree grew, or was cut back. Either way the rows on screen are out
    /// of date, and a branch that has just appeared has checksums nobody has
    /// read yet.
    private func treeChanged(_ change: LazyUEFITree.Change) {
        switch change {
        case .built, .invalidated:
            if case .invalidated = change {
                generation += 1
                checkedIDs = []
                nodeRepairs = [:]
                checksumProblems = [:]
                askedForAddresses = false
            }
            verifyNewChecksums()
            show(publish: true, rowsChanged: true)
        case .expanded, .addressesResolved:
            // A branch appearing does not move the rows on screen: the panel
            // opens the row it was asked to open, itself, when the branch is
            // there. What changes here is what the rows *say*.
            verifyNewChecksums()
            show(rowsChanged: false)
        }
    }

    /// What the reader has open, written through to where the tree lives. It
    /// is about the file, not about this session: the panel is built again on
    /// every activation, and the branches are still read.
    private func rememberOpenRows() {
        treeProvider?.setOpenUEFIRows(controller.openRows)
    }

    /// The image as the tree has it right now — the top level plus whatever
    /// has been opened, with the mapping if it has been resolved.
    private var currentImage: UEFIImage? {
        guard let tree, tree.isReady else { return nil }
        return tree.image()
    }

    /// The catalogue download: in the background, so it never blocks a reading
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

    /// Reads the checksums of every node that has appeared since the last
    /// time, and of no others.
    ///
    /// A checksum pass reads whole file bodies, so it never runs on show or in
    /// a table callback — and, with a tree that grows a branch at a time, it
    /// never runs over the whole image either: each branch is read once, when
    /// it appears, and a reader who never opens a volume never pays for its
    /// files.
    private func verifyNewChecksums(then completion: (() -> Void)? = nil) {
        // A completion waits for every pass that is running, not only for the
        // one this call starts: the tree announces a new branch to its
        // observers before it answers whoever asked for it, so the pass over
        // that branch is already in flight by the time the asker gets here and
        // finds nothing left to read.
        if let completion { checksumWaiters.append(completion) }
        defer { if checksumPassesInFlight == 0 { drainChecksumWaiters() } }

        guard let tree, tree.isReady else { return }
        let image = tree.image()
        let candidates = image.allNodes.filter {
            $0.kind == .volume || $0.kind == .file || $0.kind == .microcode
        }
        let fresh = Set(candidates.map(\.id)).subtracting(checkedIDs)
        guard !fresh.isEmpty else { return }
        checkedIDs.formUnion(fresh)

        let reader = tree.imageReader
        let generation = self.generation
        checksumPassesInFlight += 1
        Task { [weak self] in
            let pass = await UEFIToolSession.checksums(in: image, only: fresh, reader: reader)
            guard let self else { return }
            self.checksumPassesInFlight -= 1
            defer { if self.checksumPassesInFlight == 0 { self.drainChecksumWaiters() } }
            guard self.generation == generation else { return }
            self.nodeRepairs.merge(pass.nodeRepairs) { _, new in new }
            self.checksumProblems.merge(pass.badChecksums) { _, new in new }
            self.show()
            self.onChecksums?()
        }
    }

    private func drainChecksumWaiters() {
        let waiting = checksumWaiters
        checksumWaiters.removeAll()
        for waiter in waiting { waiter() }
    }

    /// Off the main actor: the pass reads every file body it covers.
    private nonisolated static func checksums(
        in image: UEFIImage,
        only ids: Set<NodeID>,
        reader: ImageReader
    ) async -> ChecksumPass {
        await Task.detached(priority: .utility) {
            let nodeRepairs = UEFIChecksumCheck.repairs(in: image, only: ids, reader: reader)
            return ChecksumPass(
                nodeRepairs: nodeRepairs,
                badChecksums: UEFIChecksumCheck.fields(of: nodeRepairs, in: image)
            )
        }.value
    }

    /// Everything the panel shows, in one call: the tree, the detail for the
    /// node in focus, and — unless told not to — the one zone that node
    /// publishes. A reveal answers with the tree and nothing else: the dump is
    /// where the user is standing, so it shows without publishing, because a
    /// newly published focus would make the host scroll the dump to the node's
    /// start and away from the caret that asked.
    ///
    /// `rowsChanged` says whether the *set* of rows can have moved, which is
    /// what decides between rebuilding the table and re-rendering what is
    /// already in it (`UEFIToolViewController.show`).
    ///
    /// Publishing is off by default, and deliberately: most shows are redraws
    /// — a branch arriving, a checksum pass landing, the GUID catalogue —
    /// and republishing on one of those would move the dump under a reader who
    /// did nothing. Only a show that follows a change of focus, or a fresh
    /// reading of the file, says what the dump should be drawing.
    private func show(publish: Bool = false, rowsChanged: Bool = false) {
        guard let tree, tree.isReady else {
            controller.show(
                image: nil, tree: tree, focus: nil, detail: .empty, catalogue: guids,
                badChecksums: checksumProblems, canWrite: !host.isReadOnly,
                isBuilding: tree != nil, rowsChanged: true
            )
            if publish { host.publish(.empty) }
            return
        }
        // The mapping is asked for the first time a node is in focus, and not
        // before: it is the detail's Address row that wants it, and working it
        // out means opening the containers on the way to the Volume Top File.
        // A panel nobody has clicked in has no address to show and pays for
        // none. When it lands the tree says so, and this runs again.
        if focus != nil, !askedForAddresses, !tree.addressesResolved {
            askedForAddresses = true
            tree.resolveAddresses {}
        }
        let image = tree.image()
        let reader = tree.imageReader
        let node = focus.flatMap { image.node($0) }
        let detail = node.map {
            UEFIDetail.build(
                for: $0, image: image, reader: reader,
                repairs: nodeRepairs[$0.id] ?? []
            )
        } ?? .empty
        controller.show(
            image: image, tree: tree, focus: focus, detail: detail, catalogue: guids,
            badChecksums: checksumProblems, canWrite: !host.isReadOnly, isBuilding: false,
            rowsChanged: rowsChanged
        )
        if publish { host.publish(UEFIPresenter.zones(for: node)) }
    }

    // MARK: - What the panel asks for

    /// The user picked a node in the tree. Publishing again is what moves the
    /// outline in the dump, and the host brings a newly focused zone on screen
    /// by itself.
    private func select(_ nodeID: NodeID?) {
        focus = nodeID
        show(publish: true)
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
        guard let image = currentImage,
              let title = UEFITreeDisplay.present(image).title
        else { return }
        focus = title.id
        show(publish: true)
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the node it stands for to the front —
    /// expand the tree to it and select it, which is the half only this side
    /// knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        guard let nodeID = UEFIPresenter.nodeID(ofZone: id) else { return }
        focus = nodeID
        show(publish: true)
    }

    /// The node the caret in the dump stands in, shown in the tree: expanded,
    /// its row selected, its detail up. The offset is where the user is
    /// pointing — the start of a selection when there is one, else the caret —
    /// and the innermost node whose range covers it is the one that owns the
    /// byte. Only the tree moves: the dump is where the user is standing, so
    /// nothing is published that would scroll it away from that caret.
    ///
    /// Public because a click on the title-row button is driven the same way
    /// the panel's other clicks are — through the session, not a simulated
    /// mouse.
    public func revealNodeAtCaret() {
        let offset = host.selection?.lowerBound ?? host.caret
        guard let tree, tree.isReady else { return }
        // The one place that asks the tree for an *offset* rather than for a
        // row, so it is also the one that has to open the branches on the way
        // to it: the node under the caret may sit inside a volume nobody has
        // read yet, and a tree that has not read it has nothing to reveal.
        //
        // Which means this answers later, and can take as long as opening that
        // branch does. The bar says so for the whole of it — a button that
        // answers a moment later and says nothing in between is a button the
        // reader takes for broken and presses again.
        controller.showBusy()
        tree.materialize(containing: offset) { [weak self] chain in
            guard let self else { return }
            self.controller.endBusy()
            guard let node = chain.last else { return }
            self.focus = node.id
            self.show(publish: false)
        }
    }

    // MARK: - Fix Checksum

    /// Recompute a node's checksum and write the corrected bytes as one
    /// undoable step. A read-only file refuses; otherwise the node's current
    /// bytes are re-read off the main actor — they may have changed since the
    /// pass that flagged them — and whatever still differs is applied, ⌘Z
    /// taking it back. The write invalidates the branch it landed in, which
    /// clears the red flag and the icon on their own, so the "written" line
    /// survives exactly that one re-read.
    ///
    /// The node comes from the tree rather than from a parse of its own: it is
    /// already materialized — the row the click was on is on screen — and the
    /// only thing left to read is the handful of bytes its checksum covers.
    ///
    /// Public because a right-click cannot be simulated — this is the level the
    /// app's tests drive, the same way FIT's `fixChecksum()` is.
    public func fixChecksum(for nodeID: NodeID) {
        guard !host.isReadOnly else {
            fail("This file is open read-only.")
            return
        }
        guard let tree, tree.isReady, let image = currentImage,
              let node = image.node(nodeID)
        else {
            fail("Could not read the file.")
            return
        }
        let revision = UEFIChecksumCheck.volumeRevision(of: node, in: image)
        let reader = tree.imageReader
        controller.showBusy()
        Task { [weak self] in
            let repairs = await UEFIToolSession.prepareChecksumFix(
                node, volumeRevision: revision, reader: reader
            )
            guard let self else { return }
            self.controller.endBusy()
            guard let repairs, !repairs.isEmpty else {
                // Nothing to write: its checksum already checks out — the flag
                // the click answered was a stale one.
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

    /// Re-read the node's bytes off the main actor and return the writes that
    /// put its checksum right, or nil when it already checks out.
    private nonisolated static func prepareChecksumFix(
        _ node: UEFINode,
        volumeRevision: UInt8?,
        reader: ImageReader
    ) async -> [ChecksumRepair]? {
        await Task.detached(priority: .userInitiated) {
            let repairs = UEFIChecksumCheck.repairs(
                for: node, volumeRevision: volumeRevision, in: reader
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
