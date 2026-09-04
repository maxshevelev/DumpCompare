import Foundation

/// Finding a pattern without being told how it is stored (§11).
///
/// A dump holds bytes, and a string in a dump is in whichever encoding the
/// firmware's author happened to use. The reader usually knows *what* they are
/// looking for and not *how it is written* — so the encoding becomes a result
/// rather than an instruction: the pattern is looked for in one encoding after
/// another, and the first one that finds anything is the answer.
///
/// The whole of that lives here, in the model: which questions to ask, in what
/// order, and the pass that asks them. What a view does with the answer — put
/// the encoding in a popup, plate the match, say what came back empty — is the
/// view's business, and it needs none of this to decide it.
public enum SmartSearch {
    /// One thing to look for.
    ///
    /// `encodings` can name more than one, because more than one can ask the
    /// same question: `abc` as ASCII and as UTF-8 is the same three bytes
    /// compared the same way, and scanning a dump twice for them would be
    /// twice the wait for one answer. They are one attempt, answering for
    /// both — and the first of them is the one a field adopts, being the
    /// narrower claim.
    public struct Attempt: Equatable, Sendable {
        public let pattern: SearchPattern
        /// How letters compare, which is part of the question rather than of
        /// the caller's bookkeeping: the same bytes compared exactly and
        /// compared folded are two different searches.
        public let folding: CaseFolding
        public let encodings: [SearchEncoding]

        public init(pattern: SearchPattern, folding: CaseFolding,
                    encodings: [SearchEncoding]) {
            self.pattern = pattern
            self.folding = folding
            self.encodings = encodings
        }

        /// The encoding a field adopts when this attempt is the one that finds
        /// a match.
        public var encoding: SearchEncoding { encodings.first ?? pattern.encoding }
    }

    /// What a pass came back with.
    public enum Outcome: Equatable, Sendable {
        /// This attempt found this range, and every attempt before it found
        /// nothing. `wrapped` when the range came from the scan that started
        /// at the file's edge rather than the one that started at the anchor —
        /// something only the pass can know, and worth saying (§11).
        case found(attempt: Attempt, range: Range<UInt64>, wrapped: Bool)
        /// Every attempt was tried and none of them found anything.
        case nothing
    }

    /// Whether `text` reads as a hexadecimal byte sequence, and so should be
    /// looked for as bytes before it is looked for as text.
    ///
    /// Deliberately stricter than the hex parser, which accepts any grouping:
    /// the question here is not "could this be parsed as hex" but "does this
    /// look like it was *meant* as hex". So an even run of hex digits —
    /// `DEADBEEF` — or those digits in pairs — `DE AD BE EF`. Anything else,
    /// `DEAD BEEF` included, is text as far as this test is concerned; a reader
    /// who means those four bytes writes them the way every hex dump prints
    /// them.
    public static func looksLikeHexBytes(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let groups = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return false }
        if groups.count == 1 { return groups[0].count % 2 == 0 }
        return groups.allSatisfy { $0.count == 2 }
    }

    /// The encodings a text pattern is tried in, in order: the ones a reader is
    /// most likely to have meant first. ASCII before UTF-8 because they ask the
    /// same question of a plain string and ASCII is the narrower claim; the
    /// UTF-16 pair after them, where a string in a dump is stored two bytes to
    /// a character.
    public static let textOrder: [SearchEncoding] = [.ascii, .utf8, .utf16LE, .utf16BE]

    /// What to look for, in the order to look: hex first when the text reads as
    /// hex, then the text encodings.
    ///
    /// Attempts asking the same question are merged, so the file is scanned
    /// once per question rather than once per encoding. An encoding that cannot
    /// encode the text at all is left out — there is nothing to look for — and
    /// a text no encoding can carry yields no attempts, which is the caller's
    /// cue that there is no pattern here rather than a bad one.
    public static func attempts(for text: String, caseSensitive: Bool) -> [Attempt] {
        var order: [SearchEncoding] = []
        if looksLikeHexBytes(text) { order.append(.hex) }
        order.append(contentsOf: textOrder)

        var attempts: [Attempt] = []
        for encoding in order {
            guard let pattern = try? SearchEngine.parsePattern(text, encoding: encoding),
                  !pattern.bytes.isEmpty else { continue }
            let folding = CaseFolding(encoding: encoding, caseSensitive: caseSensitive)
            if let existing = attempts.firstIndex(where: {
                $0.pattern.bytes == pattern.bytes && $0.folding == folding
            }) {
                attempts[existing] = Attempt(pattern: attempts[existing].pattern,
                                             folding: attempts[existing].folding,
                                             encodings: attempts[existing].encodings + [encoding])
                continue
            }
            attempts.append(Attempt(pattern: pattern, folding: folding, encodings: [encoding]))
        }
        return attempts
    }

    /// A pass of one: the two scans a plain search runs, with the wrap, and the
    /// same answer shape. A search of a chosen encoding is this — nothing about
    /// the pass cares how many attempts it was given.
    public static func firstMatch(
        of attempt: Attempt,
        in storage: ByteStorage,
        from anchor: UInt64,
        direction: SearchDirection = .forward,
        chunkSize: Int = SearchEngine.defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Outcome {
        try firstMatch(among: [attempt], in: storage, from: anchor, direction: direction,
                       chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress)
    }

    /// Runs the attempts in order until one of them finds something.
    ///
    /// Each attempt is the two scans a plain search runs: one from `anchor` in
    /// `direction`, and — failing that — one from the file's other end, which
    /// is the wrap. So "this encoding finds nothing" means nothing anywhere in
    /// the file, not merely nothing ahead of the caret, and the pass moves on
    /// to the next encoding only when it is sure.
    ///
    /// `progress` covers the whole pass: each attempt owns its share of it, and
    /// each attempt's two scans own half of that share. Cancelling through
    /// `shouldCancel` throws `CancellationError` from the scan in flight, as a
    /// single search does — a wrong guess about an encoding costs a scan of the
    /// file, and several of them are a wait worth being able to stop.
    public static func firstMatch(
        among attempts: [Attempt],
        in storage: ByteStorage,
        from anchor: UInt64,
        direction: SearchDirection = .forward,
        chunkSize: Int = SearchEngine.defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Outcome {
        guard !attempts.isEmpty else { return .nothing }
        let total = Double(attempts.count)
        for (position, attempt) in attempts.enumerated() {
            let base = Double(position)
            func scan(from offset: UInt64, half: Double) throws -> Range<UInt64>? {
                try SearchEngine.find(pattern: attempt.pattern.bytes, in: storage, from: offset,
                                      direction: direction, folding: attempt.folding,
                                      chunkSize: chunkSize, shouldCancel: shouldCancel,
                                      progress: { progress((base + half + $0 / 2) / total) })
            }
            if let range = try scan(from: anchor, half: 0) {
                return .found(attempt: attempt, range: range, wrapped: false)
            }
            let edge: UInt64 = direction == .forward ? 0 : storage.size
            if let range = try scan(from: edge, half: 0.5) {
                return .found(attempt: attempt, range: range, wrapped: true)
            }
            progress((base + 1) / total)
        }
        return .nothing
    }
}
