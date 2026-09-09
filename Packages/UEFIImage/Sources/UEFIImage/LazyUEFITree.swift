import Foundation

/// One shared, incrementally-materialized parse of an image: the same tree
/// `UEFIParser.parse(_:)` would produce, but with a volume's file list and a
/// raw-area region's signature scan computed only when something asks for
/// them — driven by an outline view's on-demand `NSOutlineViewDataSource`
/// calls — and kept from then on, until `invalidate` drops what an edit has
/// made stale.
///
/// Everything else (a file's sections, a section's nested content) is always
/// computed as soon as its containing volume is expanded: that walk is driven
/// by each file/section's own recorded size field, not a byte-by-byte scan,
/// and stays fast even for a few hundred files — the two genuinely expensive
/// operations in this parser are a raw-area region's linear scan for volume
/// signatures (`Parser.scanRawArea`) and, at one further remove, a volume's
/// own file walk once found; deferring both is what buys the laziness this
/// type exists for, deferring the rest would only cost correctness (a file's
/// name, when it comes from a UI section, would otherwise show differently
/// before and after its own expansion).
///
/// Not `Sendable`: it is mutable, per-pane, main-actor-confined state. Unlike
/// `UEFIImage`, which is a `Sendable` value returned by the still-fully-eager
/// `UEFIParser.parse(_:)` — used unchanged by consumers that need the whole
/// tree at once (`UEFIChecksumCheck`, `SecondPass`).
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
    private let source: any ByteSource
    private let reader: ImageReader
    private let limits: UEFIParser.Limits

    /// The whole tree materialized so far. Root-level and every node reached
    /// by `stampIDs` at build time; a collapsed volume/region node's own
    /// `children` is `[]` with `isExpandable == true` until `expand` fills it
    /// in, at which point that one node's `children` is replaced in place.
    private var roots: [UEFINode] = []

    /// Generation, bumped on every `invalidate`/`reset`, so a background
    /// region-scan that finishes after the tree has moved on is discarded
    /// instead of being written into a now-stale path.
    private var generation = 0

    /// Region ids with a `Task.detached` scan in flight, and the callbacks
    /// waiting on it — a second `expand` call on the same id while one is
    /// already running coalesces onto it rather than starting a duplicate.
    private var expandingIDs: Set<NodeID> = []
    private var expandingCallbacks: [NodeID: [@MainActor ([UEFINode]) -> Void]] = [:]

    public init(_ source: any ByteSource, limits: UEFIParser.Limits = .init()) {
        self.source = source
        self.reader = ImageReader(source)
        self.limits = limits
        rebuildRoots()
    }

    /// The top level — always available, computed once in `init`/`reset`.
    public var rootNodes: [UEFINode] {
        roots
    }

    /// Looks the node up by its path from the root, descending through
    /// whatever has been expanded so far. Nil past the point the tree is
    /// still collapsed, or for a path that never existed.
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
    /// background), whatever was last computed otherwise. Never triggers
    /// work by itself.
    public func children(of id: NodeID) -> [UEFINode] {
        node(id)?.children ?? []
    }

    /// Whether the outline should draw a disclosure triangle for this node —
    /// either it has children already, or it is a collapsed volume/region
    /// that would if expanded.
    public func isExpandable(_ id: NodeID) -> Bool {
        guard let node = node(id) else { return false }
        return node.isExpandable || !node.children.isEmpty
    }

    /// Whether a background scan for this node's children is currently
    /// running (`expand` was called on a region and has not returned yet).
    public func isExpanding(_ id: NodeID) -> Bool {
        expandingIDs.contains(id)
    }

    /// The descriptor's region range, without expanding anything: a plain
    /// re-read of the fixed-offset region table, independent of whether the
    /// region itself (or anything else) has ever been expanded. The entry
    /// point for MEA's ME-region lookup — cheap even the first time it is
    /// called on a freshly-built tree.
    public func region(_ type: FlashRegionType) -> Range<UInt64>? {
        guard let intelRoot = roots.first(where: { $0.kind == .intelImage }) else { return nil }
        let parser = Parser(reader: reader, limits: limits, expansion: NeverExpandPolicy.shared)
        return parser.flashRegionRange(
            type, descriptorAt: intelRoot.body.lowerBound, limit: intelRoot.body.upperBound
        )
    }

    /// Expands `id`: materializes its children if they are not already known,
    /// and calls `onReady` with them either way. A volume's file list is
    /// cheap (header-driven, no scanning) and is computed synchronously,
    /// before `expand` returns. A region's raw-area scan is the one
    /// genuinely expensive operation this type defers, and runs in a
    /// background `Task.detached`; `onReady` is called later, on the main
    /// actor, once it completes. Calling `expand` again on an id already
    /// expanding coalesces the new callback onto the one in flight rather
    /// than starting a second scan.
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

        switch target.kind {
        case .volume:
            let parser = Parser(reader: reader, limits: limits, expansion: NeverExpandPolicy.shared)
            var stamped: [UEFINode] = []
            if let header = parser.readVolumeHeader(at: target.header.lowerBound) {
                let raw = parser.volumeChildren(header, body: target.body, depth: id.path.count)
                stamped = LazyUEFITree.stampIDs(raw, under: id)
            }
            applyExpansion(id, children: stamped)
            onReady(stamped)

        case .region:
            guard let subtype = target.subtype, FlashRegionType(rawValue: Int(subtype)) != nil else {
                applyExpansion(id, children: [])
                onReady([])
                return
            }
            expandingIDs.insert(id)
            expandingCallbacks[id] = [onReady]
            let capturedGeneration = generation
            let capturedReader = reader
            let capturedLimits = limits
            let range = target.body
            let depth = id.path.count
            Task.detached(priority: .userInitiated) { [weak self] in
                let parser = Parser(
                    reader: capturedReader, limits: capturedLimits, expansion: NeverExpandPolicy.shared
                )
                let raw = parser.scanRawArea(range, emptyByte: Parser.defaultEmptyByte, depth: depth + 1)
                await self?.completeRegionExpansion(id, raw: raw, expectedGeneration: capturedGeneration)
            }

        default:
            // Nothing else is ever left collapsed (isExpandable == false for
            // every other kind), so this should not be reached in practice.
            applyExpansion(id, children: [])
            onReady([])
        }
    }

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
        expandingIDs.removeAll()
        expandingCallbacks.removeAll()

        if sizeDelta == 0 {
            roots = LazyUEFITree.collapsingOverlapping(roots, range: editedRange)
        } else {
            roots = LazyUEFITree.collapsingFrom(roots, offset: editedRange.lowerBound)
        }
    }

    /// Applies a background region scan's result, unless the tree has moved
    /// on (another edit landed, or the tree was reset) since it started.
    private func completeRegionExpansion(_ id: NodeID, raw: [UEFINode], expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        let stamped = LazyUEFITree.stampIDs(raw, under: id)
        applyExpansion(id, children: stamped)
        let callbacks = expandingCallbacks.removeValue(forKey: id) ?? []
        expandingIDs.remove(id)
        for callback in callbacks { callback(stamped) }
    }

    // MARK: - Private

    private func rebuildRoots() {
        let parser = Parser(reader: reader, limits: limits, expansion: NeverExpandPolicy.shared)
        roots = parser.run().roots
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

    /// Ids are stamped relative to `parent` the same way `UEFIImage` stamps a
    /// freshly-built tree — the parser itself never carries a counter, a
    /// node's place is only known once its parent has decided to keep it.
    private static func stampIDs(_ nodes: [UEFINode], under parent: NodeID) -> [UEFINode] {
        nodes.enumerated().map { index, node in
            var stamped = node
            stamped.id = parent.child(index)
            stamped.children = stampIDs(node.children, under: stamped.id)
            return stamped
        }
    }
}
