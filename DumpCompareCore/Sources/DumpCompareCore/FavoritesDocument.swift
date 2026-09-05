import Foundation

/// What this machine keeps on disk: the library it believes in, and the state
/// it last agreed on with a shared file (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// Two roles that must not be the same bytes. The **local** library is the
/// truth — what the app reads and draws, always available, ahead of the base
/// whenever something has been added and not yet published. The **base** is the
/// last state agreed with the shared file, and it is what makes a merge
/// three-way: without it every field that differs looks like a conflict and the
/// user is asked about all of them.
///
/// One file, written atomically, because two files would let a crash leave a
/// base from one round beside a truth from another.
public struct FavoritesDocument: Equatable, Sendable, Codable {
    public var format: Int
    /// What this machine believes.
    public var local: PatternLibrary
    /// The last state agreed with each of the other machines, by the name of
    /// the file it writes.
    ///
    /// One base per peer, because there is one file per machine: what this Mac
    /// last agreed with the laptop says nothing about what it last agreed with
    /// the desk. A single base was the shape of a single shared file, and a
    /// single shared file is what two machines cannot both write.
    public var bases: [String: PatternLibrary]

    public init(local: PatternLibrary = PatternLibrary(),
                bases: [String: PatternLibrary] = [:],
                format: Int = PatternLibrary.currentFormat) {
        self.format = format
        self.local = local
        self.bases = bases
    }

    enum CodingKeys: String, CodingKey {
        case format, local, bases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? PatternLibrary.currentFormat
        local = try container.decode(PatternLibrary.self, forKey: .local)
        bases = try container.decodeIfPresent([String: PatternLibrary].self, forKey: .bases) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(local, forKey: .local)
        try container.encode(bases, forKey: .bases)
    }

    // MARK: - The file

    public func fileContents() throws -> Data {
        try PatternLibrary.encoder().encode(self)
    }

    /// Reads the file back.
    ///
    /// A file written before the base existed is a bare library rather than a
    /// document, and it is read as one — the library it holds is this machine's
    /// truth, with nothing agreed yet. Older files stay readable, which is the
    /// same promise the library itself makes.
    public init(fileContents data: Data) throws {
        let decoder = PatternLibrary.decoder()
        if let document = try? decoder.decode(FavoritesDocument.self, from: data) {
            self = document
            return
        }
        self.init(local: try PatternLibrary(fileContents: data))
    }
}
