import Foundation

/// One shared, incrementally-materialized parse of an image: the tree every
/// UEFI-aware tool-module reads, built once per open file and kept for as long
/// as the file is open.
///
/// Nothing here is parsed before something asks for it. Building the tree
/// yields the top level and no more — an Intel image's regions, a capsule's
/// envelope, or the raw-area scan that decides what the top level of a plain
/// chip dump even is — and every container below that is left closed, with
/// `isExpandable` set, until an outline row is opened, an address is resolved,
/// or a FIT row's target is looked up. `invalidate` then narrows an edit down
/// to the volume or region it landed in, so a byte typed in one volume never
/// costs the file its other volumes' already-materialized files.
///
/// That is what makes switching tool panels free: the second panel to ask
/// finds the first one's work already done, and asks only for whatever more it
/// needs.
///
/// Not `Sendable`: it is mutable, per-pane, main-actor-confined state. The
/// heavy half of every expansion runs off the main actor as a
/// `TreeMaterialization` call over the (Sendable) reader, and only the result
/// comes back here to be written into the tree.
///
/// A `ByteSource` this tree is built against is expected to be *live*: it
/// should read whatever bytes are currently in the underlying storage, not a
/// point-in-time snapshot — the app wraps the open file's actual, mutable
/// `EditOverlayStorage` (a thread-safe reference type) rather than taking a
/// fresh snapshot on every edit. That is what lets `invalidate` be just
/// "forget these memoized subtrees" rather than "also swap in fresher bytes
/// first": whichever node is expanded next simply reads through to storage as
/// it is at that moment, collapsed or not.
@MainActor
public final class LazyUEFITree {
    /// The bytes, reachable without the main actor so a background
    /// materialization — and a tool-module reading a header of its own — works
    /// from exactly the content this tree was built against.
    public nonisolated let source: any ByteSource
    public nonisolated var imageReader: ImageReader { ImageReader(source) }

    private let reader: ImageReader
    private let limits: UEFIParser.Limits

    /// The whole tree materialized so far. A closed container's own `children`
    /// is `[]` with `isExpandable == true` until an expansion fills it in, at
    /// which point that one node's `children` is replaced in place.
    private var roots: [UEFINode] = []
    /// What the parses so far had to complain about, in the order they were
    /// found. Grows as the tree does — a volume's "unknown file system" is not
    /// known until something opens that volume.
    private var diagnostics: [UEFIDiagnostic] = []

    /// `address = offset + addressDiff`, from the Volume Top File (§5.7), once
    /// `resolveAddresses` has looked for it. Nil while it has not been asked
    /// for, and nil afterwards when the image has no VTF to anchor it.
    public private(set) var addressDiff: UInt64?
    /// The image's own statement of where it is loaded, read alongside the
    /// address mapping (§5.7).
    public private(set) var resetVector: ResetVector?
    /// Whether the VTF descent has been run since the tree was last
    /// invalidated. Told apart from `addressDiff == nil`, which is also the
    /// answer for an image that genuinely has no VTF.
    public private(set) var addressesResolved = false

    /// Whether the top level is there yet. False only between `init` and the
    /// end of the background build — which on a plain chip dump is a scan of
    /// the whole file, and on an Intel image is instant.
    public private(set) var isReady = false

    /// Generation, bumped on every `invalidate`, so a background scan that
    /// finishes after the tree has moved on is discarded instead of being
    /// written into a now-stale path.
    private var generation = 0

    /// Ids with a materialization in flight, and the callbacks waiting on it —
    /// a second `expand` on the same id while one is already running coalesces
    /// onto it rather than starting a duplicate.
    private var expandingIDs: Set<NodeID> = []
    private var expandingCallbacks: [NodeID: [@MainActor ([UEFINode]) -> Void]] = [:]
    /// Waiting on the top level, for callers that arrived before the build
    /// finished.
    private var readyCallbacks: [@MainActor () -> Void] = []
    /// Waiting on the VTF descent, likewise.
    private var addressCallbacks: [@MainActor () -> Void] = []
    private var isResolvingAddresses = false

    /// The last `image()`, held until something changes the tree. Building one
    /// walks every node materialized so far, and a panel asks for it on every
    /// show.
    private var cachedImage: UEFIImage?

    /// Where the Volume Top File starts, once the mapping has been worked out.
    /// Kept because the tail look finds it without opening the containers
    /// around it, so the node itself may not be in the tree yet — and has to
    /// be marked fixed when it arrives.
    private var fixedAnchor: UInt64?

    /// Who to tell when the tree has grown or been cut back. A panel keeps one
    /// of these to reload its rows; a session keeps one to check the checksums
    /// of whatever just appeared. Tokens rather than a single slot because two
    /// tool-module sessions can be alive at once — one on screen, one parked —
    /// and the parked one must not be able to unsubscribe the other.
    public struct ObserverToken: Hashable, Sendable {
        fileprivate let value: Int
    }
    private var observers: [ObserverToken: @MainActor (Change) -> Void] = [:]
    private var nextObserverToken = 0

    /// What an observer is told. `nodeID` is nil for the top level itself —
    /// the build landing, or an invalidation that cut somewhere unknowable
    /// from here.
    public enum Change: Sendable {
        /// The top level is there; the tree can be read.
        case built
        /// This node's children were materialized.
        case expanded(NodeID)
        /// The VTF descent landed: the mapping is known, and the chain it
        /// opened on the way is now part of the tree.
        case addressesResolved
        /// An edit dropped memoized subtrees; everything below is suspect.
        case invalidated
    }

    public init(_ source: any ByteSource, limits: UEFIParser.Limits = .init()) {
        self.source = source
        self.reader = ImageReader(source)
        self.limits = limits
        build()
    }

    // MARK: - Reading what is there

    /// The top level. Empty until `isReady`.
    public var rootNodes: [UEFINode] {
        roots
    }

    /// What the parses so far had to complain about.
    public var currentDiagnostics: [UEFIDiagnostic] {
        diagnostics
    }

    /// Looks the node up by its path from the root, descending through
    /// whatever has been expanded so far. Nil past the point the tree is
    /// still closed, or for a path that never existed.
    public func node(_ id: NodeID) -> UEFINode? {
        var nodes = roots
        var found: UEFINode?
        for index in id.path {
            guard index >= 0, index < nodes.count else { return nil }
            found = nodes[index]
            nodes = found!.children
        }
        return found
    }

    /// This node's immediate children as currently materialized — empty for a
    /// node that has not been expanded yet (or is expanding in the
    /// background), whatever was last computed otherwise. Never triggers work
    /// by itself.
    public func children(of id: NodeID) -> [UEFINode] {
        node(id)?.children ?? []
    }

    /// Whether the outline should draw a disclosure triangle for this node —
    /// either it has children already, or it is a closed container that would
    /// if expanded.
    public func isExpandable(_ id: NodeID) -> Bool {
        guard let node = node(id) else { return false }
        return node.isExpandable || !node.children.isEmpty
    }

    /// Whether a background materialization for this node's children is
    /// currently running.
    public func isExpanding(_ id: NodeID) -> Bool {
        expandingIDs.contains(id)
    }

    /// The tree so far as one `Sendable` value — what a pure consumer
    /// (`UEFIDetail`, `FITReader`, `UEFIChecksumCheck`) reads, and what a
    /// background task can be handed. It is the whole tree only if everything
    /// has been expanded; otherwise it is exactly as much of the image as has
    /// been asked for, with the addresses resolved so far.
    public func image() -> UEFIImage {
        if let cachedImage { return cachedImage }
        let image = UEFIImage(
            size: reader.count,
            roots: roots,
            diagnostics: diagnostics,
            addressDiff: addressDiff,
            resetVector: resetVector
        )
        // Kept until the tree next changes: building one copies every node
        // materialized so far, and a panel asks for it on every selection.
        cachedImage = image
        return image
    }

    /// The descriptor's region range, without expanding anything: a plain
    /// re-read of the fixed-offset region table, independent of whether the
    /// region itself — or the tree at all — has been built yet. The entry
    /// point for MEA's ME-region lookup, and cheap even on a tree that is
    /// still building its top level.
    public func region(_ type: FlashRegionType) -> Range<UInt64>? {
        let parser = Parser(reader: reader, limits: limits)
        let body: Range<UInt64>
        if let intelRoot = roots.first(where: { $0.kind == .intelImage }) {
            body = intelRoot.body
        } else if parser.hasDescriptorSignature(at: 0) {
            body = reader.all
        } else {
            return nil
        }
        return parser.flashRegionRange(
            type, descriptorAt: body.lowerBound, limit: body.upperBound
        )
    }

    // MARK: - Waiting

    /// Calls `body` once the top level is there — immediately when it already
    /// is. A panel that wants to draw its first rows starts here.
    public func whenReady(_ body: @escaping @MainActor () -> Void) {
        if isReady {
            body()
        } else {
            readyCallbacks.append(body)
        }
    }

    // MARK: - Growing the tree

    /// Expands `id`: materializes its children if they are not already known,
    /// and calls `onReady` with them either way.
    ///
    /// Always asynchronous when there is work to do — the file walk of a
    /// volume and the signature scan of a raw-area region are both off the
    /// main actor, and both leave `isExpanding(id)` true until they land, so a
    /// panel can put a "Loading…" row where the children will go. A node whose
    /// children are already known answers before this returns. Calling
    /// `expand` again on an id already expanding coalesces the new callback
    /// onto the one in flight rather than starting a second scan.
    public func expand(_ id: NodeID, onReady: @escaping @MainActor ([UEFINode]) -> Void) {
        guard let target = node(id) else {
            onReady([])
            return
        }
        guard target.children.isEmpty else {
            onReady(target.children)
            return
        }
        guard target.isExpandable else {
            onReady([])
            return
        }
        if expandingIDs.contains(id) {
            expandingCallbacks[id, default: []].append(onReady)
            return
        }

        expandingIDs.insert(id)
        expandingCallbacks[id] = [onReady]
        let capturedGeneration = generation
        let capturedReader = reader
        let capturedLimits = limits
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = TreeMaterialization.children(
                of: target, reader: capturedReader, limits: capturedLimits
            )
            await self?.completeExpansion(
                id, result: result, expectedGeneration: capturedGeneration
            )
        }
    }

    /// Expands every container on the way down to `offset` and hands back the
    /// chain that covers it, outermost first.
    ///
    /// What a caller with an address rather than a row asks: a FIT entry's
    /// target, the element a microcode run lives in. It costs one expansion
    /// per level of the chain and nothing at all for the rest of the image.
    public func materialize(
        containing offset: UInt64,
        _ done: @escaping @MainActor ([UEFINode]) -> Void
    ) {
        whenReady { [weak self] in
            guard let self else { return }
            self.step(containing: offset, from: .root, chain: [], done: done)
        }
    }

    private func step(
        containing offset: UInt64,
        from parent: NodeID,
        chain: [UEFINode],
        done: @escaping @MainActor ([UEFINode]) -> Void
    ) {
        let siblings = parent.path.isEmpty ? roots : children(of: parent)
        guard let index = siblings.firstIndex(where: { $0.range.contains(offset) }) else {
            done(chain)
            return
        }
        let id = parent.child(index)
        let found = siblings[index]
        let chain = chain + [found]
        guard found.children.isEmpty, found.isExpandable else {
            step(containing: offset, from: id, chain: chain, done: done)
            return
        }
        expand(id) { [weak self] _ in
            guard let self else { return }
            // The node was replaced in place by the expansion; the chain keeps
            // the version that now has children.
            let refreshed = self.node(id) ?? found
            self.step(
                containing: offset, from: id,
                chain: Array(chain.dropLast()) + [refreshed], done: done
            )
        }
    }

    /// Works out where the image is mapped, and reads the reset vector with it
    /// (§10) — then calls `done`, immediately when it has already been worked
    /// out since the last edit.
    ///
    /// The anchor is the Volume Top File, whose final byte is the last byte of
    /// the address space — so on an image mapped flush to the top of it, the
    /// VTF is what the image *ends with*, and a look at the tail finds it
    /// without opening anything at all. That is the fast path, and the common
    /// one: measured on a 24 MiB dump it is the difference between an address
    /// that is there and one that is half a second late.
    ///
    /// Where the tail says nothing — an image mapped some other way, a region
    /// cut out of one — it falls back to walking: down the chain of nodes that
    /// reaches the last byte, opening the three or four containers on the way.
    /// No VTF at all is not a defect either: a dump of one BIOS region, or of
    /// an EC, has none, and `addressDiff` staying nil is the whole of what
    /// that means.
    public func resolveAddresses(_ done: @escaping @MainActor () -> Void) {
        whenReady { [weak self] in
            guard let self else { return }
            if self.addressesResolved {
                done()
                return
            }
            self.addressCallbacks.append(done)
            guard !self.isResolvingAddresses else { return }
            self.isResolvingAddresses = true

            let parser = Parser(reader: self.reader, limits: self.limits)
            if let vtf = parser.volumeTopFileInTail() {
                let second = parser.secondPass(anchoredOn: vtf)
                if second.addressDiff != nil {
                    self.landAddresses(
                        second, anchor: vtf.range.lowerBound,
                        diagnostics: parser.diagnostics
                    )
                    return
                }
            }
            self.descendToTheLastNode(from: .root) { [weak self] in
                self?.finishResolvingAddresses()
            }
        }
    }

    /// Opens the container that reaches furthest into the image, then the one
    /// inside that, and so on to the bottom — through `expand`, one node at a
    /// time, rather than over a copy of the tree in the background.
    ///
    /// Through `expand` on purpose: a copy would have to be written back
    /// wholesale when it landed, and a branch somebody opened meanwhile —
    /// while this descent was running — would be thrown away with it.
    private func descendToTheLastNode(
        from parent: NodeID, _ done: @escaping @MainActor () -> Void
    ) {
        let siblings = parent.path.isEmpty ? roots : children(of: parent)
        guard let index = siblings.indices.max(by: {
            siblings[$0].range.upperBound < siblings[$1].range.upperBound
        }) else {
            done()
            return
        }
        let id = parent.child(index)
        let node = siblings[index]
        guard node.children.isEmpty else {
            descendToTheLastNode(from: id, done)
            return
        }
        guard node.isExpandable else {
            done()
            return
        }
        expand(id) { [weak self] _ in
            self?.descendToTheLastNode(from: id, done)
        }
    }

    /// Reads the mapping off whatever the descent found. An edit that landed
    /// while it was running has already cleared `isResolvingAddresses`, and
    /// that is what says this answer is about a tree that no longer exists.
    private func finishResolvingAddresses() {
        guard isResolvingAddresses else { return }
        let parser = Parser(reader: reader, limits: limits)
        var updated = roots
        let second = updated.isEmpty ? Parser.SecondPass() : parser.runSecondPass(&updated)
        roots = updated
        let anchor = second.addressDiff.map { 0x1_0000_0000 - $0 }
        landAddresses(
            second,
            anchor: anchor.flatMap { top in
                findNode(in: roots) { $0.range.upperBound == top && $0.guid == KnownGUIDs.volumeTopFile }
            }?.range.lowerBound,
            diagnostics: parser.diagnostics
        )
    }

    /// Publishes a mapping, however it was arrived at: the anchor is marked
    /// where the tree already reaches it, remembered for the branches that
    /// have yet to be opened, and everyone waiting is told.
    private func landAddresses(
        _ second: Parser.SecondPass, anchor: UInt64?, diagnostics newDiagnostics: [UEFIDiagnostic]
    ) {
        guard isResolvingAddresses else { return }
        isResolvingAddresses = false
        diagnostics += newDiagnostics
        addressDiff = second.addressDiff
        resetVector = second.resetVector
        addressesResolved = true
        fixedAnchor = anchor
        markTheAnchor()
        cachedImage = nil
        let waiting = addressCallbacks
        addressCallbacks.removeAll()
        announce(.addressesResolved)
        for callback in waiting { callback() }
    }

    /// The VTF is the anchor for every address in the image, so moving it moves
    /// everything (§11) — and its node says so. It is marked wherever the tree
    /// already reaches it, and again each time a branch that might contain it
    /// is opened, because the mapping is usually known long before the volume
    /// holding the VTF has been walked.
    private func markTheAnchor() {
        guard let fixedAnchor else { return }
        let parser = Parser(reader: reader, limits: limits)
        var updated = roots
        parser.markFixed(&updated, at: fixedAnchor)
        roots = updated
        cachedImage = nil
    }

    private func findNode(
        in nodes: [UEFINode], where matches: (UEFINode) -> Bool
    ) -> UEFINode? {
        for node in nodes {
            if matches(node) { return node }
            if let found = findNode(in: node.children, where: matches) { return found }
        }
        return nil
    }

    // MARK: - Invalidation

    /// Invalidates the parts of the tree an edit may have made stale. There is
    /// no wholesale `reset` — a caller whose file was replaced outright
    /// (revert, a file joined on) simply drops this instance and builds a new
    /// one against the new content; nothing here needs to handle that case.
    ///
    /// A pure overwrite (`sizeDelta == 0`) collapses only the volume/region
    /// nodes whose range overlaps `editedRange` — descending through
    /// everything else (the intelImage root, the descriptor, already-expanded
    /// files and sections, which are never gated on their own) to find them,
    /// so a byte changed in one volume never disturbs a sibling volume's
    /// already-materialized files.
    ///
    /// A size-changing edit (`sizeDelta != 0`) collapses every volume/region
    /// node whose range reaches `editedRange.lowerBound` or beyond, at every
    /// level — everything after the edit point may have shifted, everything
    /// before it provably has not.
    ///
    /// Either way, this only drops memoized *structure* — the byte source
    /// itself is live, so whichever node is expanded next (collapsed by this
    /// call or not) reads current bytes regardless.
    public func invalidate(editedRange: Range<UInt64>, sizeDelta: Int64) {
        generation += 1
        // Whoever was waiting on work this edit has just made pointless is
        // told so at the end of this call rather than left waiting: a caller
        // suspended on one of these — a tool-module awaiting a branch or the
        // mapping — would otherwise never be resumed at all.
        let abandonedExpansions = expandingCallbacks
        let abandonedAddresses = addressCallbacks
        expandingIDs.removeAll()
        expandingCallbacks.removeAll()
        // The mapping is anchored on a node that may have just moved, and the
        // reset vector is bytes that may have just been typed over.
        addressesResolved = false
        addressDiff = nil
        resetVector = nil
        fixedAnchor = nil
        isResolvingAddresses = false
        addressCallbacks.removeAll()
        // The diagnostics of the subtrees being dropped go with them; what is
        // left is re-collected as those subtrees are expanded again.
        diagnostics.removeAll()
        cachedImage = nil

        if sizeDelta == 0 {
            roots = LazyUEFITree.collapsingOverlapping(roots, range: editedRange)
        } else {
            roots = LazyUEFITree.collapsingFrom(roots, offset: editedRange.lowerBound)
        }
        // An edit that lands before the top level is even there has just made
        // the build in flight stale — its result is dropped by the generation
        // bump above, so without a fresh one the tree would never become
        // readable at all.
        if !isReady { build() }
        announce(.invalidated)

        for callbacks in abandonedExpansions.values {
            for callback in callbacks { callback([]) }
        }
        for callback in abandonedAddresses { callback() }
    }

    // MARK: - Observers

    /// Registers `observer` and hands back the token that removes it again.
    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor (Change) -> Void) -> ObserverToken {
        nextObserverToken += 1
        let token = ObserverToken(value: nextObserverToken)
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeValue(forKey: token)
    }

    private func announce(_ change: Change) {
        for observer in observers.values { observer(change) }
    }

    // MARK: - Private

    /// The top level, off the main actor: on a plain chip dump this is the
    /// signature scan of the whole file, which is the one thing about opening
    /// an image that is never free.
    private func build() {
        let capturedReader = reader
        let capturedLimits = limits
        let capturedGeneration = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = TreeMaterialization.roots(
                reader: capturedReader, limits: capturedLimits
            )
            await self?.completeBuild(result, expectedGeneration: capturedGeneration)
        }
    }

    private func completeBuild(
        _ result: TreeMaterialization.Result, expectedGeneration: Int
    ) {
        guard generation == expectedGeneration else { return }
        roots = TreeMaterialization.stampIDs(result.nodes, under: .root)
        diagnostics = result.diagnostics
        cachedImage = nil
        isReady = true
        let waiting = readyCallbacks
        readyCallbacks.removeAll()
        announce(.built)
        for callback in waiting { callback() }
    }

    /// Applies a background materialization's result, unless the tree has
    /// moved on (an edit landed) since it started.
    private func completeExpansion(
        _ id: NodeID, result: TreeMaterialization.Result, expectedGeneration: Int
    ) {
        guard generation == expectedGeneration else { return }
        let stamped = TreeMaterialization.stampIDs(result.nodes, under: id)
        applyExpansion(id, children: stamped)
        diagnostics += result.diagnostics
        cachedImage = nil
        markTheAnchor()
        let callbacks = expandingCallbacks.removeValue(forKey: id) ?? []
        expandingIDs.remove(id)
        announce(.expanded(id))
        for callback in callbacks { callback(stamped) }
    }

    /// Replaces the children of the node at `id.path` with `children`, and
    /// marks that node no longer expandable — this is its final, materialized
    /// state now, whether or not `children` turned out empty.
    private func applyExpansion(_ id: NodeID, children: [UEFINode]) {
        guard !id.path.isEmpty else { return }
        roots = LazyUEFITree.replacingChildren(of: roots, at: id.path, with: children)
    }

    private static func replacingChildren(
        of nodes: [UEFINode], at path: [Int], with children: [UEFINode]
    ) -> [UEFINode] {
        guard let index = path.first, index >= 0, index < nodes.count else { return nodes }
        var result = nodes
        if path.count == 1 {
            result[index].children = children
            result[index].isExpandable = false
        } else {
            result[index].children = replacingChildren(
                of: result[index].children, at: Array(path.dropFirst()), with: children
            )
        }
        return result
    }

    /// True for the two kinds this tree ever leaves collapsed. Every other
    /// kind's children, once computed, stay computed until an ancestor gate
    /// point above it is itself collapsed.
    private static func isGatePoint(_ node: UEFINode) -> Bool {
        node.kind == .volume || node.kind == .region
    }

    /// Collapses the narrowest already-materialized gate point(s) overlapping
    /// `range` — never an ancestor gate point whose *other* children do not
    /// overlap. Each node tries narrowing into its own children first; only
    /// when nothing below it changed does it collapse itself, which is what
    /// keeps a region's other, untouched volumes materialized when the edit
    /// landed inside just one of them.
    private static func collapsingOverlapping(_ nodes: [UEFINode], range: Range<UInt64>) -> [UEFINode] {
        nodes.map { collapseOneOverlapping($0, range: range).node }
    }

    private static func collapseOneOverlapping(
        _ node: UEFINode, range: Range<UInt64>
    ) -> (node: UEFINode, changed: Bool) {
        var node = node
        guard node.range.overlaps(range), !node.children.isEmpty else { return (node, false) }
        let results = node.children.map { collapseOneOverlapping($0, range: range) }
        if results.contains(where: \.changed) {
            node.children = results.map(\.node)
            return (node, true)
        }
        if isGatePoint(node) {
            node.children = []
            node.isExpandable = true
            return (node, true)
        }
        // Overlapping, has children, not a gate point (a file/section, never
        // gated on its own) — nothing narrower to collapse.
        return (node, false)
    }

    /// Same narrowing as `collapsingOverlapping`, but for a size-changing
    /// edit: everything at or after `offset` may have shifted, so the trigger
    /// is "ends after the edit point" rather than "overlaps a range".
    private static func collapsingFrom(_ nodes: [UEFINode], offset: UInt64) -> [UEFINode] {
        nodes.map { collapseOneFrom($0, offset: offset).node }
    }

    private static func collapseOneFrom(
        _ node: UEFINode, offset: UInt64
    ) -> (node: UEFINode, changed: Bool) {
        var node = node
        guard node.range.upperBound > offset, !node.children.isEmpty else { return (node, false) }
        let results = node.children.map { collapseOneFrom($0, offset: offset) }
        if results.contains(where: \.changed) {
            node.children = results.map(\.node)
            return (node, true)
        }
        if isGatePoint(node) {
            node.children = []
            node.isExpandable = true
            return (node, true)
        }
        return (node, false)
    }
}
