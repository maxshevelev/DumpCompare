import Foundation

/// What a rule must not decide on its own (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// Everything a merge *can* answer, it answers silently — the whole point of
/// keeping a base is that most differences are one side changing something the
/// other did not touch. What is left is genuinely two people saying different
/// things about the same entry, and that is a question, not a rule.
public enum LibraryConflict: Equatable, Sendable {
    /// The same entry, changed differently on both sides.
    case bothEdited(ours: SearchPatternEntry, theirs: SearchPatternEntry)
    /// Changed on one machine, deleted on the other — the classic, and the one
    /// where a rule either loses an edit or resurrects something deliberately
    /// removed.
    ///
    /// `entry` is the *edited* version whichever side this machine is on, since
    /// a deletion has nothing to show; `deletedHere` says which side that is.
    /// Both machines have to ask, or the one that deleted decides for the one
    /// that edited: it would fold the other's counters into its own without a
    /// question, and counters that cover the other machine's version are how an
    /// answer travels — so the deletion would arrive there as somebody's answer
    /// and take the edit with it.
    case editedAndDeleted(entry: SearchPatternEntry, deletedBy: String, deletedHere: Bool)
    /// Both sides kept the same search, under different names. One entry has to
    /// go (§11 keeps one search once), and which name it carries is not the
    /// app's to choose.
    case sameSearchTwoNames(ours: SearchPatternEntry, theirs: SearchPatternEntry)

    /// The entry the question is about, on this machine's side.
    public var id: UUID {
        switch self {
        case .bothEdited(let ours, _), .sameSearchTwoNames(let ours, _):
            return ours.id
        case .editedAndDeleted(let entry, _, _):
            return entry.id
        }
    }
}

/// Which side of a conflict the user kept.
public enum LibraryResolution: Equatable, Sendable {
    case keepOurs
    case keepTheirs
    /// Both, as two entries. Only offered where they are genuinely different
    /// searches — keeping one search twice is what §11 refuses.
    case keepBoth
}

/// Merging two versions of the library against the state they last agreed on
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// A shared file is not a lock: between one machine's write and the other
/// seeing it there are seconds to minutes, and in that window the other is
/// editing a copy that is already stale. So every read of the shared file goes
/// through here, and the base — the last state both sides agreed on — is what
/// turns "these two lists differ" into "this side changed that field", which is
/// the difference between one question and twenty.
public enum LibraryMerge {
    /// How long a deletion is remembered. Long enough for a machine that was
    /// off for a holiday to hear about it; short enough that the file does not
    /// grow forever. Getting it wrong resurrects a pattern.
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    public struct Outcome: Equatable, Sendable {
        /// The merged library — usable as it stands. Where a conflict was
        /// found this machine's version is kept, so the app has something true
        /// to show while the question is unanswered.
        public var library: PatternLibrary
        /// What the user has to answer. Empty means the merge is complete and
        /// may be written.
        public var conflicts: [LibraryConflict]

        public init(library: PatternLibrary, conflicts: [LibraryConflict]) {
            self.library = library
            self.conflicts = conflicts
        }

        public var isResolved: Bool { conflicts.isEmpty }
    }

    /// Merges `theirs` into `ours` against `base`, the last state the two
    /// agreed on. `base` is nil the first time this machine ever sees the file
    /// — then there is no common past, and every entry either side has is kept.
    /// `assumeConcurrent` skips the question of who saw what, for a version
    /// whose vector says nothing: a copy a sync client left beside the file is
    /// a lineage of its own, and its empty vector is a lack of information
    /// rather than evidence of having seen nothing.
    public static func merge(base: PatternLibrary?, ours: PatternLibrary,
                             theirs: PatternLibrary, assumeConcurrent: Bool = false,
                             now: Date = Date()) -> Outcome {
        // Nothing concurrent about it: one side has seen everything the other
        // wrote, so the version that has seen more simply wins. This is the
        // ordinary case — one machine writes, the other reads it later.
        if !assumeConcurrent, !ours.vector.isConcurrent(with: theirs.vector) {
            if theirs.vector.dominates(ours.vector), !ours.vector.dominates(theirs.vector) {
                return Outcome(library: pruned(theirs, now: now), conflicts: [])
            }
            if ours.vector.dominates(theirs.vector) {
                return Outcome(library: pruned(ours, now: now), conflicts: [])
            }
        }

        var conflicts: [LibraryConflict] = []
        var merged = PatternLibrary(format: max(ours.format, theirs.format))
        merged.vector = ours.vector.merged(with: theirs.vector)
        merged.tombstones = mergedTombstones(ours: ours, theirs: theirs)

        let baseByID = index(base?.entries ?? [])
        let oursByID = index(ours.entries)
        let theirsByID = index(theirs.entries)
        let deletedByThem = tombstonesByID(theirs)
        let deletedByUs = tombstonesByID(ours)

        // A deterministic pass: this machine's entries in their order, then
        // whatever the file has that this machine has never seen. Two machines
        // merging the same pair must reach the same list, so nothing here may
        // depend on a dictionary's iteration order.
        var order = ours.entries.map(\.id)
        order.append(contentsOf: theirs.entries.map(\.id).filter { oursByID[$0] == nil })

        var kept: [SearchPatternEntry] = []
        for id in order {
            let base = baseByID[id]
            switch (oursByID[id], theirsByID[id]) {
            case let (mine?, yours?):
                if mine == yours {
                    // The same thing said twice. The file's copy carries the
                    // order, since the file's order leads.
                    kept.append(preferringOrder(of: yours, content: mine))
                } else if let base, mine == base {
                    kept.append(yours)                    // only they changed it
                } else if let base, yours == base {
                    kept.append(mine)                     // only we changed it
                } else {
                    conflicts.append(.bothEdited(ours: mine, theirs: yours))
                    kept.append(mine)                     // something true to show meanwhile
                }
            case let (mine?, nil):
                if let tombstone = deletedByThem[id] {
                    // They deleted it. If we changed it since the base, that is
                    // a question; if we did not, the deletion stands.
                    if let base, mine != base {
                        conflicts.append(.editedAndDeleted(entry: mine,
                                                           deletedBy: tombstone.device,
                                                           deletedHere: false))
                        kept.append(mine)
                    } else if base == nil, outlives(mine, tombstone) {
                        // The base says nothing about this entry, so there is
                        // no causal answer — and one is needed, because the
                        // other machine's file goes on carrying that tombstone.
                        // Without this, keeping an entry against a deletion was
                        // undone by the very next merge with the machine that
                        // deleted it: the answer removed the note here, and the
                        // note came straight back from there.
                        kept.append(mine)
                    }
                } else {
                    // Absent without a tombstone is not evidence of a deletion
                    // — a line removed from the file by hand comes back, which
                    // is the safe way round.
                    kept.append(mine)
                }
            case let (nil, yours?):
                if let tombstone = deletedByUs[id] {
                    // We deleted it, and if they changed it since the base this
                    // is the same question from the other side. Nothing is
                    // kept: what this machine says meanwhile is the deletion.
                    if let base, yours != base {
                        conflicts.append(.editedAndDeleted(entry: yours,
                                                           deletedBy: tombstone.device,
                                                           deletedHere: true))
                    } else if base == nil, outlives(yours, tombstone) {
                        // The mirror of the rule above, and it has to be the
                        // same rule: two machines applying different ones to
                        // the same pair would settle on different answers and
                        // hand them to each other for ever.
                        kept.append(yours)
                    }
                } else {
                    kept.append(yours)
                }
            case (nil, nil):
                continue
            }
        }

        // Two sides can keep the same search under two ids without either
        // knowing — §11 keeps one search once, so one has to go.
        let (deduplicated, duplicateConflicts) = deduplicate(kept, ours: oursByID, theirs: theirsByID)
        conflicts.append(contentsOf: duplicateConflicts)

        merged.entries = ordered(deduplicated, theirs: theirsByID)
        return Outcome(library: pruned(merged, now: now), conflicts: conflicts)
    }

    /// Applies the user's answers to a merge that had questions, giving a
    /// library that can be written.
    public static func resolve(_ outcome: Outcome,
                               with answers: [UUID: LibraryResolution],
                               now: Date = Date()) -> PatternLibrary {
        var library = outcome.library
        for conflict in outcome.conflicts {
            guard let answer = answers[conflict.id] else { continue }
            switch (conflict, answer) {
            case let (.bothEdited(_, theirs), .keepTheirs),
                 let (.sameSearchTwoNames(_, theirs), .keepTheirs):
                library.entries.removeAll { $0.id == conflict.id || $0.id == theirs.id }
                library.entries.append(theirs)
            case let (.bothEdited(_, theirs), .keepBoth),
                 let (.sameSearchTwoNames(_, theirs), .keepBoth):
                if !library.entries.contains(where: { $0.id == theirs.id }) {
                    library.entries.append(theirs)
                }
            case let (.editedAndDeleted(entry, _, deletedHere), .keepTheirs)
                where !deletedHere:
                // Their answer was to delete it, so this machine's edit goes
                // and the deletion is recorded properly.
                library.entries.removeAll { $0.id == entry.id }
                if !library.tombstones.contains(where: { $0.id == entry.id }) {
                    library.tombstones.append(PatternLibrary.Tombstone(id: entry.id,
                                                                       device: entry.device))
                }
            case let (.editedAndDeleted(entry, _, _), .keepTheirs):
                // This machine deleted it and the answer was to keep theirs, so
                // the deletion goes and their version comes back.
                library.tombstones.removeAll { $0.id == entry.id }
                if !library.entries.contains(where: { $0.id == entry.id }) {
                    library.entries.append(revived(entry, at: now))
                }
            case let (.editedAndDeleted(entry, _, deletedHere), .keepOurs),
                 let (.editedAndDeleted(entry, _, deletedHere), .keepBoth):
                // Keeping the edit means taking the deletion back. Where the
                // deletion is this machine's own answer there is nothing to do:
                // the merged library already says it.
                if !deletedHere {
                    library.tombstones.removeAll { $0.id == entry.id }
                    library.entries = library.entries.map {
                        $0.id == entry.id ? revived($0, at: now) : $0
                    }
                }
            case (_, .keepOurs):
                break   // the merged library already holds ours
            }
        }
        return library
    }

    /// An entry kept against a deletion, stamped as changed now.
    ///
    /// The stamp is the answer itself: the machine that deleted it still has
    /// the note, and the note outlives an entry last touched before it. Keeping
    /// something is a change to the library made at the moment it is decided,
    /// so saying so is both true and what makes the decision stick.
    private static func revived(_ entry: SearchPatternEntry, at now: Date) -> SearchPatternEntry {
        var kept = entry
        kept.modifiedAt = now
        return kept
    }

    // MARK: - Parts

    /// Whether an entry is later than a deletion of it — the tiebreak used
    /// only where the base can say nothing, because the entry is not in it.
    ///
    /// Clocks are not the arbiter of a merge and never become one here: this
    /// decides between a note and an entry that have no common past, where the
    /// alternative is either resurrecting whatever anyone ever deleted or
    /// deleting whatever anyone ever revived. The two events are a person's
    /// deliberate actions minutes apart, which is well outside the skew between
    /// two Macs.
    private static func outlives(_ entry: SearchPatternEntry,
                                 _ tombstone: PatternLibrary.Tombstone) -> Bool {
        entry.modifiedAt > tombstone.deletedAt
    }

    private static func index(_ entries: [SearchPatternEntry]) -> [UUID: SearchPatternEntry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func tombstonesByID(_ library: PatternLibrary) -> [UUID: PatternLibrary.Tombstone] {
        Dictionary(library.tombstones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func mergedTombstones(ours: PatternLibrary,
                                         theirs: PatternLibrary) -> [PatternLibrary.Tombstone] {
        var all = tombstonesByID(ours)
        for (id, tombstone) in tombstonesByID(theirs) {
            if let existing = all[id], existing.deletedAt >= tombstone.deletedAt { continue }
            all[id] = tombstone
        }
        return all.values.sorted { $0.deletedAt < $1.deletedAt }
    }

    /// An entry says what this machine says, and sits where the file says: the
    /// file's order leads, so nobody's reordering is undone by the other's.
    private static func preferringOrder(of theirs: SearchPatternEntry,
                                        content: SearchPatternEntry) -> SearchPatternEntry {
        var result = content
        result.sortKey = theirs.sortKey
        return result
    }

    /// One search is kept once (§11). Where both sides added it under one name,
    /// the copy that stays is decided by a rule both machines compute the same
    /// way — the smaller id — so the two do not each keep the other's.
    private static func deduplicate(_ entries: [SearchPatternEntry],
                                    ours: [UUID: SearchPatternEntry],
                                    theirs: [UUID: SearchPatternEntry])
    -> ([SearchPatternEntry], [LibraryConflict]) {
        var kept: [SearchPatternEntry] = []
        var conflicts: [LibraryConflict] = []
        for entry in entries {
            guard let twin = kept.firstIndex(where: { $0.isSameSearch(as: entry) }) else {
                kept.append(entry)
                continue
            }
            let existing = kept[twin]
            if existing.name == entry.name {
                if entry.id.uuidString < existing.id.uuidString { kept[twin] = entry }
                continue
            }
            // Two names for one search: whose name is the user's to say.
            let mine = ours[existing.id] != nil ? existing : entry
            let yours = ours[existing.id] != nil ? entry : existing
            conflicts.append(.sameSearchTwoNames(ours: mine, theirs: yours))
            kept[twin] = mine
        }
        return (kept, conflicts)
    }

    /// The file's order leads; entries only this machine has are appended after
    /// everything the file places.
    private static func ordered(_ entries: [SearchPatternEntry],
                                theirs: [UUID: SearchPatternEntry]) -> [SearchPatternEntry] {
        let placed = entries.compactMap { theirs[$0.id] != nil ? $0 : nil }
        let highest = placed.map(\.sortKey).max() ?? 0
        var next = highest
        return entries.map { entry in
            guard theirs[entry.id] == nil, entry.sortKey <= highest else { return entry }
            var moved = entry
            next += PatternLibrary.sortKeyStep
            moved.sortKey = next
            return moved
        }
    }

    /// Drops deletions that contradict the result, and those old enough that
    /// every machine has had a chance to see them. A tombstone kept forever is a file that grows forever; one dropped
    /// too early is a pattern that comes back.
    private static func pruned(_ library: PatternLibrary, now: Date) -> PatternLibrary {
        var result = library
        // An entry that is here and a note saying it was deleted cannot both be
        // true. The keeping won — either because only one side deleted it and
        // the other had changed it, or because someone was asked and said so —
        // and leaving the note behind would delete it again on the next merge.
        let alive = Set(library.entries.map(\.id))
        result.tombstones = library.tombstones.filter {
            !alive.contains($0.id) && now.timeIntervalSince($0.deletedAt) < tombstoneLifetime
        }
        return result
    }
}
