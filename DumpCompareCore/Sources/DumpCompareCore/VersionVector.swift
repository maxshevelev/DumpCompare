import Foundation

/// How many times each machine has written a library
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// It answers the one question timestamps cannot: were two versions of a
/// library written **concurrently**, or did one see the other first? Two Macs'
/// clocks disagree by more than a sync takes, so "later" is not a fact about
/// order — but "this version already includes every write that one knows about"
/// is, and that is all a merge needs to know before it starts asking the user
/// questions.
public struct VersionVector: Equatable, Sendable {
    /// Per device, the number of writes by that device this version reflects.
    public private(set) var counters: [String: Int]

    public init(_ counters: [String: Int] = [:]) {
        self.counters = counters
    }

    public subscript(device: String) -> Int { counters[device] ?? 0 }

    public var isEmpty: Bool { counters.isEmpty }

    /// Counts one more write by `device`.
    public mutating func increment(for device: String) {
        counters[device, default: 0] += 1
    }

    /// Whether this version includes every write the other one knows about.
    /// A version that dominates another is simply ahead of it: taking it loses
    /// nothing, and no merge is needed.
    public func dominates(_ other: VersionVector) -> Bool {
        other.counters.allSatisfy { self[$0.key] >= $0.value }
    }

    /// Neither one has seen everything the other has: both were written from a
    /// common past without knowing about each other. This is the case the merge
    /// exists for.
    public func isConcurrent(with other: VersionVector) -> Bool {
        !dominates(other) && !other.dominates(self)
    }

    /// The version that has seen both — what a merged library carries.
    public func merged(with other: VersionVector) -> VersionVector {
        var union = counters
        for (device, count) in other.counters {
            union[device] = max(union[device] ?? 0, count)
        }
        return VersionVector(union)
    }
}

extension VersionVector: Codable {
    /// Written as the bare dictionary it is, so the file stays legible.
    public init(from decoder: Decoder) throws {
        counters = try decoder.singleValueContainer().decode([String: Int].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counters)
    }
}
