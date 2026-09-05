import Foundation

/// The kept patterns as a document: what is written to a file, and what two
/// machines exchange (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// JSON rather than a plist, because the argument for a file at all includes
/// being able to read a diff of it — a library under version control, or sent
/// to someone, has to be legible.
///
/// Three fields carry the syncing, and all three are here from the first
/// version even though only `entries` is used yet: a format that gains fields
/// later is a format with two readers, and the file is the one thing another
/// machine's build has to understand.
public struct PatternLibrary: Equatable, Sendable {
    /// The format the file was written in. Read back defensively: a file from
    /// a newer build is not thrown away, it is read for what this build knows.
    public var format: Int
    /// The kept patterns, in the order they are shown.
    public var entries: [SearchPatternEntry]
    /// Entries that were deleted, kept long enough for another machine to hear
    /// about it. Without them "you deleted it" and "you never had it" are the
    /// same absence, and a merge resurrects whatever either side removed.
    public var tombstones: [Tombstone]
    /// How many times each machine has written this library. What makes a
    /// *concurrent* write tellable from a later one — timestamps cannot, since
    /// two Macs' clocks disagree by more than a sync takes.
    public var vector: VersionVector
    /// Which Mac wrote this copy, in the words its owner uses — the machine's
    /// name at the moment of writing.
    ///
    /// For a person reading the folder, and for nothing else. The file is
    /// *named* after a hash of the machine's id, because a name a network hands
    /// out cannot be part of a filename that has to stay put; the name itself
    /// belongs here, where changing it is a changed line rather than a new
    /// file. Two copies saying the same thing are the same library whoever
    /// wrote them, which is why this is not part of `==`.
    public var machine: String

    public static let currentFormat = 1

    public init(entries: [SearchPatternEntry] = [], tombstones: [Tombstone] = [],
                vector: VersionVector = VersionVector(), machine: String = "",
                format: Int = currentFormat) {
        self.format = format
        self.entries = entries
        self.tombstones = tombstones
        self.vector = vector
        self.machine = machine
    }

    /// Two libraries are equal when they *say* the same thing. Who wrote the
    /// copy is not part of that: every machine writes its own name into its own
    /// file, so counting it would make every comparison between two machines'
    /// copies false — and those comparisons are what decide whether anything
    /// needs writing at all.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.format == rhs.format && lhs.entries == rhs.entries
            && lhs.tombstones == rhs.tombstones && lhs.vector == rhs.vector
    }

    /// A deleted entry: which one, when, and by whom.
    public struct Tombstone: Equatable, Sendable, Codable {
        public let id: UUID
        public var deletedAt: Date
        public var device: String

        public init(id: UUID, deletedAt: Date = Date(), device: String = "") {
            self.id = id
            self.deletedAt = deletedAt
            self.device = device
        }
    }

    // MARK: - Order

    /// The entries in the order the user put them in, which is what `sortKey`
    /// holds. Entries that have never been placed (a sort key of zero, from a
    /// row written before any of this) keep the order they arrived in — a
    /// stable sort, so reading a migrated library twice gives the same list.
    public var ordered: [SearchPatternEntry] {
        entries.enumerated()
            .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
            .map(\.element)
    }

    /// Replaces the entries with `list`, in that order, spacing their sort keys
    /// so a later insertion has room between any two of them.
    public mutating func setOrder(_ list: [SearchPatternEntry]) {
        entries = list.enumerated().map { index, entry in
            var placed = entry
            placed.sortKey = Double(index + 1) * Self.sortKeyStep
            return placed
        }
    }

    /// The gap left between neighbours. Large enough that inserting between two
    /// of them repeatedly halves for a long time before the numbers get close.
    public static let sortKeyStep: Double = 1024

    /// The same library in the one form it is written in.
    ///
    /// Entries in the order they are *shown* — which `sortKey` decides, not the
    /// array — and tombstones in a fixed one. Two machines merging the same
    /// facts hold them in different array orders (each puts its own first), and
    /// without this "does the file already say that" answers no every time:
    /// each side rewrites the file in its own order, the other sees a change,
    /// and the two sync each other for ever.
    public var canonical: PatternLibrary {
        var result = self
        result.entries = ordered
        result.tombstones = tombstones.sorted { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    /// A sort key that places an entry between two others — what a dragged row
    /// asks for, without renumbering everything below it.
    public static func sortKey(between above: Double?, and below: Double?) -> Double {
        switch (above, below) {
        case let (above?, below?): return (above + below) / 2
        case let (above?, nil): return above + sortKeyStep
        case let (nil, below?): return below - sortKeyStep
        case (nil, nil): return sortKeyStep
        }
    }
}

// MARK: - The file

extension PatternLibrary: Codable {
    enum CodingKeys: String, CodingKey {
        case format, entries, tombstones, vector, machine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Everything but the entries is optional on the way in: a file written
        // by a build that had no tombstones yet is a valid library, not an
        // error to report to someone who only wants their patterns.
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? Self.currentFormat
        entries = try container.decodeIfPresent([SearchPatternEntry].self, forKey: .entries) ?? []
        tombstones = try container.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
        vector = try container.decodeIfPresent(VersionVector.self, forKey: .vector) ?? VersionVector()
        machine = try container.decodeIfPresent(String.self, forKey: .machine) ?? ""
    }
}

extension SearchEncoding: Codable {}

extension PatternLibrary {
    /// The bytes to write. Pretty-printed with sorted keys: the file is meant
    /// to be read by a person and diffed by a tool, and a diff of one changed
    /// name should be one changed line.
    public func fileContents() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// The encoder both the library and the document are written with.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamps.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Whole seconds too: a file written by hand, or by a tool that does
            // not bother with fractions, is still a file.
            guard let date = timestamps.date(from: text) ?? wholeSeconds.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not a timestamp: \(text)"))
            }
            return date
        }
        return decoder
    }

    /// Reads a library back. Throws only when the bytes are not a library at
    /// all — every field it can do without is optional (see the decoder).
    public init(fileContents data: Data) throws {
        self = try Self.decoder().decode(PatternLibrary.self, from: data)
    }

    /// ISO 8601 with fractional seconds. Whole seconds would be enough for a
    /// merge tiebreak, but a timestamp that does not survive a round trip makes
    /// every "is this the same library" comparison quietly false.
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds = ISO8601DateFormatter()
}
