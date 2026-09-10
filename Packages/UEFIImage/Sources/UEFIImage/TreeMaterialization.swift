import Foundation

/// The one place a collapsed node's children are computed from the bytes.
///
/// The parser never opens the two containers that cost a scan — a raw-area
/// region and a volume's body — so what `Parser` returns is always a tree with
/// holes in it. Filling one is this type's whole job, and both drivers go
/// through it: `LazyUEFITree`, which fills one node at a time off the main
/// actor as something asks for it, and `UEFIParser.parse(_:)`, which fills
/// every one of them in a row and hands back the finished `UEFIImage` a test
/// or an oracle comparison wants.
///
/// Free of state of its own — every function takes the reader and gives back
/// what it computed — so a `Task.detached` can call it without carrying an
/// object across the isolation boundary.
enum TreeMaterialization {
    /// Nodes, and whatever the parse of them had to complain about. The
    /// diagnostics travel with the nodes because a lazy tree accumulates them
    /// as it expands: a volume's "unknown file system" is not known until
    /// something opens that volume.
    /// `Sendable` because a lazy tree computes one of these off the main actor
    /// and hands it back when it lands.
    struct Result: Sendable {
        var nodes: [UEFINode]
        var diagnostics: [UEFIDiagnostic]
    }

    /// The top level, and nothing below it that can be deferred: a capsule's
    /// envelope, an Intel image's regions, or — for an image with no
    /// descriptor — the raw-area scan that decides what the top level even is.
    ///
    /// That last one is the one case where "the top level" costs a walk of the
    /// whole file: nothing announces the structures in a plain chip dump but
    /// the signatures inside it, so they have to be looked for before there is
    /// anything to show. It is why a caller builds this off the main actor.
    static func roots(
        reader: ImageReader,
        limits: UEFIParser.Limits,
        progress: ProgressSink? = nil
    ) -> Result {
        let parser = Parser(reader: reader, limits: limits, progress: progress)
        let nodes = reader.count == 0 ? [] : parser.parseTopLevel(reader.all, depth: 0)
        return Result(nodes: nodes, diagnostics: parser.diagnostics)
    }

    /// One collapsed node's children, parsed at the depth the node itself
    /// recorded when it was left closed (`UEFINode.childDepth`) — so a node
    /// expanded now lands exactly where an all-at-once parse would have put
    /// it, recursion limit included.
    static func children(
        of node: UEFINode,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        progress: ProgressSink? = nil
    ) -> Result {
        guard node.isExpandable else { return Result(nodes: [], diagnostics: []) }
        let parser = Parser(reader: reader, limits: limits, progress: progress)
        switch node.kind {
        case .volume:
            guard let header = parser.readVolumeHeader(at: node.header.lowerBound) else {
                return Result(nodes: [], diagnostics: parser.diagnostics)
            }
            return Result(
                nodes: parser.volumeChildren(header, body: node.body, depth: node.childDepth),
                diagnostics: parser.diagnostics
            )
        case .region:
            return Result(
                nodes: parser.scanRawArea(
                    node.body, emptyByte: Parser.defaultEmptyByte, depth: node.childDepth
                ),
                diagnostics: parser.diagnostics
            )
        default:
            // Nothing else is ever left collapsed, so this is unreachable in
            // practice — and answering "no children" is the honest reading of
            // a node the parser did not gate.
            return Result(nodes: [], diagnostics: [])
        }
    }

    /// Fills in `node`'s children in place and marks it materialized. The node
    /// keeps its `isExpandable` only while its children are still unknown, so
    /// a node that turned out to hold nothing does not go on offering a
    /// disclosure triangle for the rest of the session.
    static func expand(
        _ node: inout UEFINode,
        at id: NodeID,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        diagnostics: inout [UEFIDiagnostic],
        progress: ProgressSink? = nil
    ) {
        let result = children(
            of: node, reader: reader, limits: limits, progress: progress
        )
        node.children = stampIDs(result.nodes, under: id)
        node.isExpandable = false
        diagnostics += result.diagnostics
    }

    /// Opens every collapsed node there is, depth first — the whole tree, as
    /// the parser would have built it in one pass if it opened everything on
    /// the way down.
    static func materializeAll(
        _ nodes: inout [UEFINode],
        under parent: NodeID = .root,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        diagnostics: inout [UEFIDiagnostic],
        progress: ProgressSink? = nil
    ) {
        for index in nodes.indices {
            let id = parent.child(index)
            if nodes[index].isExpandable {
                expand(
                    &nodes[index], at: id, reader: reader, limits: limits,
                    diagnostics: &diagnostics, progress: progress
                )
            }
            materializeAll(
                &nodes[index].children, under: id, reader: reader,
                limits: limits, diagnostics: &diagnostics, progress: progress
            )
        }
    }

    /// Ids are stamped relative to `parent` the same way `UEFIImage` stamps a
    /// freshly-built tree — the parser itself never carries a counter, a
    /// node's place is only known once its parent has decided to keep it.
    static func stampIDs(_ nodes: [UEFINode], under parent: NodeID) -> [UEFINode] {
        nodes.enumerated().map { index, node in
            var stamped = node
            stamped.id = parent.child(index)
            stamped.children = stampIDs(node.children, under: stamped.id)
            return stamped
        }
    }
}

/// How far a materialization has got, for a caller drawing a bar.
///
/// A reference type, and shared across every `Parser` one materialization
/// runs: the fractions have to move forward across the whole job, and a
/// per-parser counter would walk the bar back to nothing at each new node.
/// Only ever driven from the thread doing the materialization — a background
/// expansion reports nothing at all, so this never crosses an isolation
/// boundary.
final class ProgressSink {
    private let total: UInt64
    private let report: (Double) -> Void
    private var last: Double = 0

    init(total: UInt64, report: @escaping (Double) -> Void) {
        self.total = total
        self.report = report
    }

    /// Reports that the scan has reached `offset`. Drops anything that would
    /// move the bar backwards or not at all: the parser does not always visit
    /// the image in order — a descriptor image parses the BIOS region and then
    /// the smaller region that sits *below* it.
    func reached(_ offset: UInt64) {
        guard total > 0 else { return }
        let fraction = min(Double(offset) / Double(total), 1)
        guard fraction > last else { return }
        last = fraction
        report(fraction)
    }
}
