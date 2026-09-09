import Foundation

/// Decides whether a container's children should be computed now or left
/// collapsed for later lazy expansion.
///
/// Checked at the two points in the parser where a linear scan or a
/// potentially large walk would otherwise run unconditionally: a raw-area
/// region's signature scan (`DescriptorParser.regionNode`), and a volume's
/// file/NVRAM-entry walk (`VolumeParser.parseVolume`). A `NodeID` is not
/// available at either call site — ids are stamped once, after the whole tree
/// returned by a `Parser` run exists (`UEFIImage.stampingIDs`) — so the
/// decision is made from the node's range alone, not its identity. The eager
/// parser uses `ExpandAllPolicy` to preserve existing behavior exactly; a
/// `LazyUEFITree` uses `NeverExpandPolicy` everywhere, always deferring at
/// both points, and re-derives a specific node's children later by calling
/// the same parser functions directly, scoped to that one node.
protocol ExpansionPolicy: AnyObject {
    func shouldExpand(range: Range<UInt64>) -> Bool
}

/// The policy the eager parser uses: always expand. Ensures
/// `UEFIParser.parse(_:)` produces the same tree as before, byte-for-byte,
/// for every existing consumer (`UEFIChecksumCheck`, `SecondPass`, tests).
final class ExpandAllPolicy: ExpansionPolicy {
    static let shared = ExpandAllPolicy()
    func shouldExpand(range: Range<UInt64>) -> Bool { true }
}

/// The policy `LazyUEFITree` uses: never expand at either gate point. Left
/// collapsed nodes are re-derived later, on demand, by `LazyUEFITree.expand`.
final class NeverExpandPolicy: ExpansionPolicy {
    static let shared = NeverExpandPolicy()
    func shouldExpand(range: Range<UInt64>) -> Bool { false }
}
