import Foundation
import ToolModuleKit
import UEFIFormat

/// Why a change to the table cannot be made.
///
/// Each of these is a rule from the specification, and each is worth saying in
/// a sentence rather than refusing silently: the user is at a bench with a
/// dump that has to boot afterwards.
public enum FITEditProblem: Equatable, Sendable, Error {
    /// The file this tool was pointed at is not a microcode image.
    case notMicrocode
    /// Its dword checksum does not come out at zero (§7.1).
    case microcodeChecksumIsWrong
    /// There is no microcode in the table to put the new one after, so there is
    /// no telling where this image keeps them (§9.2).
    case noMicrocodeToFollow
    /// No run of erased bytes long enough, in the element the existing
    /// microcode lives in. Carries what was needed, the most that was free, and
    /// where it looked — a refusal that does not say those three things leaves
    /// the user with nowhere to go.
    case noRoomForTheComponent(needed: UInt64, largestFree: UInt64, inside: String)
    /// The table has no empty slot and the bytes after it are not free, so it
    /// cannot grow (§9.1). Carries what is in the way, because "no empty slot"
    /// on its own leaves nobody anywhere to go.
    case theTableCannotGrow(after: String)
    /// A bigger component would push the run past the end of whatever holds it.
    case theRunCannotGrow(needed: UInt64)
    /// The header is not an entry to be removed (§10).
    case cannotRemoveTheHeader
    /// A table needs at least one microcode entry (§8.7).
    case cannotRemoveTheLastMicrocode
    case noSuchEntry
    /// Nothing to add to.
    case noTable

    public var message: String {
        switch self {
        case .notMicrocode:
            return "That file does not start with an Intel microcode header."
        case .microcodeChecksumIsWrong:
            return "That microcode's checksum does not add up — its dwords should sum to zero."
        case .noMicrocodeToFollow:
            return "There is no microcode in this table to put a new one after."
        case .noRoomForTheComponent(let needed, let largestFree, let inside):
            return "That microcode needs 0x" + String(needed, radix: 16, uppercase: true)
                + " bytes. The most that is free after the last microcode is 0x"
                + String(largestFree, radix: 16, uppercase: true) + ", in " + inside + "."

        case .theTableCannotGrow(let after):
            return "The table has no empty slot, and the sixteen bytes after it are not free —"
                + " they are " + after + "."

        case .theRunCannotGrow(let needed):
            return "That microcode needs 0x" + String(needed, radix: 16, uppercase: true)
                + " more bytes than the run it would go in has free."
        case .cannotRemoveTheHeader:
            return "The header is not an entry."
        case .cannotRemoveTheLastMicrocode:
            return "A FIT needs at least one microcode entry."
        case .noSuchEntry:
            return "That entry is no longer in the table."
        case .noTable:
            return "There is no FIT table in this file to change."
        }
    }
}

/// What a change to the table turned out to be, for the sentence the panel
/// says afterwards.
public struct FITEditOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A new row, for a CPUID the table did not name.
        case added
        /// A CPUID the table already named. The new component goes exactly
        /// where the old one was; what follows it in the run moves to suit.
        case replaced
    }

    public var kind: Kind
    /// Where the component went.
    public var range: Range<UInt64>
    /// The row that names it.
    public var entryIndex: Int
    /// What the replaced component was, when there was one.
    public var replaced: MicrocodeHeader?
    /// How many components behind it moved, because the new one is a different
    /// size from the old.
    public var moved: Int = 0
}

/// What a removal came to.
public struct FITRemovalOutcome: Equatable, Sendable {
    public var entryIndex: Int
    /// How many components moved up into the space the removed one left.
    public var moved: Int
    /// The bytes the move freed at the end of the run, now erased.
    public var erased: Range<UInt64>?
}

/// Where a new component would go.
public struct FITPlacement: Equatable, Sendable {
    public var range: Range<UInt64>
    /// The address it will be reachable at once written.
    public var address: UInt64
}

/// The two changes this tool makes to a table: adding a microcode entry (§9.2)
/// and taking one out (§10).
///
/// Both come back as a `ToolTransaction` rather than as writes performed here:
/// a whole edit — the component, the rows shifted around it, the header's count
/// and its checksum — has to land as one undoable step or not at all. Neither
/// changes the file's size, which §9.2 step 8 requires: a flash dump is the
/// size of the chip it came off.
public enum FITEditor {
    /// A microcode image the user picked, checked before anything is written.
    public static func microcode(
        in bytes: [UInt8]
    ) -> Result<MicrocodeHeader, FITEditProblem> {
        let reader = ImageReader(bytes)
        guard let header = MicrocodeHeader.read(at: 0, in: reader),
              header.range.upperBound <= reader.count
        else { return .failure(.notMicrocode) }
        guard Checksums.sum32(of: header.range, in: reader) == 0 else {
            return .failure(.microcodeChecksumIsWrong)
        }
        return .success(header)
    }

    /// Where a component of `size` bytes can go (§9.2 step 1).
    ///
    /// Microcode lives in one run in every image worth the name, so the search
    /// starts right after the last one the table points at and stays inside
    /// whatever holds it — padding, free space, a microcode region. Staying
    /// inside is what keeps the component from crossing into another element or
    /// out of its flash region.
    ///
    /// What this cannot check is Boot Guard: the protected ranges are in
    /// structures `UEFIFormat` does not read yet (`Design/TODO.md`), and a
    /// component written inside one stops the platform booting. The panel says
    /// so rather than pretending otherwise.
    public static func placement(
        forSize size: UInt64,
        table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64
    ) -> Result<FITPlacement, FITEditProblem> {
        guard size > 0 else { return .failure(.notMicrocode) }
        func noRoom(_ largest: UInt64, _ area: (range: Range<UInt64>, name: String)) -> FITEditProblem {
            .noRoomForTheComponent(
                needed: size,
                largestFree: largest,
                inside: "\(area.name) at 0x"
                    + String(area.range.lowerBound, radix: 16, uppercase: true) + "–0x"
                    + String(area.range.upperBound, radix: 16, uppercase: true)
            )
        }
        let components = table.rows.compactMap { row -> Range<UInt64>? in
            guard case .microcode(let header) = row.target else { return nil }
            return header.range
        }
        guard let last = components.max(by: { $0.upperBound < $1.upperBound }) else {
            return .failure(.noMicrocodeToFollow)
        }
        let areas = placementAreas(after: last, image: image, reader: reader)
        guard let start = alignUp(last.upperBound, to: 16), let first = areas.first else {
            return .failure(noRoom(0, (last, "the run")))
        }

        var largest: UInt64 = 0
        var roomiest = first
        for area in areas {
            // The first area is the element the run is in, and there the search
            // starts where the run ends rather than where the element does.
            var candidate = max(start, alignUp(area.range.lowerBound, to: 16) ?? .max)
            var free: UInt64 = 0
            while candidate + size <= area.range.upperBound {
                if reader.isFilled(candidate..<(candidate + size), with: 0xFF) {
                    return .success(FITPlacement(
                        range: candidate..<(candidate + size),
                        address: candidate + addressDiff
                    ))
                }
                guard let used = reader.firstOffset(
                    in: candidate..<min(candidate + size, area.range.upperBound),
                    notEqualTo: 0xFF
                ), let next = alignUp(used + 1, to: 16) else { break }
                free = max(free, used - candidate)
                candidate = next
            }
            // What is left at the end of an area is a run too, and usually the
            // biggest — a refusal is only useful if it names the best that was
            // on offer.
            if area.range.upperBound > candidate,
               reader.isFilled(candidate..<area.range.upperBound, with: 0xFF) {
                free = max(free, area.range.upperBound - candidate)
            }
            if free > largest {
                largest = free
                roomiest = area
            }
        }
        return .failure(noRoom(largest, roomiest))
    }

    /// The element the run lives in: the innermost node that is *space* rather
    /// than a structure. A microcode component's own node is a structure, so
    /// what holds the run is whatever contains it — and where nothing does,
    /// which is what a microcode found by the raw scan of a plain image looks
    /// like, the rest of the file does.
    ///
    /// This is what bounds a run that has to *grow in place*: pushing the last
    /// component past the end of its file or its region would put it inside the
    /// next structure along.
    private static func spareArea(
        around offset: UInt64,
        image: UEFIImage?,
        reader: ImageReader
    ) -> (range: Range<UInt64>, name: String) {
        guard let image else { return (offset..<reader.count, "the rest of the file") }
        let chain = image.nodes(containing: offset)
        for node in chain.reversed() where node.kind != .microcode {
            return (node.range, node.name)
        }
        return (offset..<reader.count, "the rest of the file")
    }

    /// Everywhere a *new* component may go, nearest first.
    ///
    /// The element holding the run comes first — right after the last
    /// microcode is where the next one belongs (§9.2 step 1). But a run whose
    /// file has no slack left is the ordinary case, and the volume's own free
    /// space usually sits directly behind that file: erased, claimed by
    /// nothing, and what a bench reaches for. So the search walks out through
    /// the containers, taking their free space and erased padding as it goes.
    ///
    /// It cannot cross out of the flash region, which §9.2 forbids, and needs
    /// no check for it: the walk only ever climbs the chain of nodes that
    /// *contain* the run, so the furthest out it can reach is the outermost of
    /// them — which in an Intel image is the region itself. Free space in
    /// another region is somebody else's, and is never even looked at.
    private static func placementAreas(
        after component: Range<UInt64>,
        image: UEFIImage?,
        reader: ImageReader
    ) -> [(range: Range<UInt64>, name: String)] {
        let element = spareArea(around: component.lowerBound, image: image, reader: reader)
        guard let image else { return [element] }
        let chain = image.nodes(containing: component.lowerBound)
        guard let elementIndex = chain.lastIndex(where: { $0.kind != .microcode }) else {
            return [element]
        }

        var areas = [element]
        var below = chain[elementIndex]
        for ancestor in chain[..<elementIndex].reversed() {
            for child in ancestor.children
            where child.range.lowerBound >= below.range.upperBound && isSpare(child, reader) {
                // Inside a volume, only the space *directly* behind the element
                // is usable. A component dropped anywhere else in a volume's
                // free space is met by that volume's own walk as a file that is
                // not one (§5.8) — the tree afterwards is full of nonsense. What
                // is adjacent can be taken into the file instead, which is what
                // `fileGrowth` does.
                if ancestor.kind == .volume, child.range.lowerBound != below.range.upperBound {
                    continue
                }
                areas.append((child.range, child.name))
            }
            below = ancestor
        }
        return areas
    }

    /// Space nothing has claimed, and nothing has been written into.
    private static func isSpare(_ node: UEFINode, _ reader: ImageReader) -> Bool {
        switch node.kind {
        case .freeSpace, .padding, .nonUEFIData:
            return node.children.isEmpty && reader.isFilled(node.range, with: 0xFF)
        default:
            return false
        }
    }

    /// Adds a microcode, or replaces the one already there for its CPUID.
    ///
    /// A dump is for one board, and the ordinary reason to open this form is
    /// that a CPUID already in the table has a newer revision. Adding a second
    /// row for the same processor would leave the FIT naming two microcodes for
    /// it — legal, wasteful, and not what anybody meant.
    ///
    /// Replacing has two shapes. Where the new component is no bigger than the
    /// old one it goes exactly where that one was, the tail of the old one is
    /// erased behind it, and *nothing about the table changes* — not the row,
    /// not the count, not even the checksum. Where it is bigger it goes
    /// wherever a new one would, and the row that named the old one is
    /// repointed. The old bytes are left where they are either way: erasing
    /// them is the risk §10 step 5 warns about.
    public static func addOrReplaceMicrocode(
        _ component: [UInt8],
        in table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64
    ) -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        let header: MicrocodeHeader
        switch microcode(in: component) {
        case .success(let read): header = read
        case .failure(let problem): return .failure(problem)
        }
        // Exactly what the header claims, so a file with something after it
        // does not drag the extra bytes into the image.
        let bytes = Array(component.prefix(Int(header.totalSize)))

        guard let row = rowNaming(header.processorSignature, matching: header, in: table),
              case .microcode(let old) = row.target
        else {
            return addingNewRow(bytes, for: header, to: table, image: image,
                                reader: reader, addressDiff: addressDiff)
        }

        switch relay(replacing: old, with: bytes, in: table, image: image, reader: reader) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let plan):
            var writes = [plan.write]
            if let growth = plan.growth { writes.append(growth.write) }
            if !plan.moves.isEmpty {
                // Only when something moved: a transaction that writes the
                // table back unchanged is a step in the undo history that
                // undoes nothing.
                guard var rows = rowBytes(of: table, in: reader) else {
                    return .failure(.noSuchEntry)
                }
                for move in plan.moves {
                    writeAddress(move.newOffset + addressDiff, into: &rows[move.rowIndex])
                }
                writes.append(ToolTransaction.Write(
                    offset: table.range.lowerBound,
                    bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
                ))
            }
            return .success((
                withContainerRepairs(
                    ToolTransaction(name: "Replace Microcode", writes: writes),
                    image: image, reader: reader, grownFile: plan.growth?.grown
                ),
                FITEditOutcome(
                    kind: .replaced,
                    range: old.offset..<(old.offset + UInt64(header.totalSize)),
                    entryIndex: row.entry.index,
                    replaced: old,
                    moved: plan.moves.count
                )
            ))
        }
    }

    /// Whether the sixteen bytes behind the table are anybody's.
    ///
    /// Erased is the plain case, but a byte is not the only evidence: a volume
    /// erased with `0x00` (§3.5) leaves free space that is not `0xFF`, and the
    /// tree knows which nodes were never written to. Where the answer is no,
    /// what is there is named — "no empty slot" on its own leaves nobody
    /// anywhere to go.
    private static func roomAfterTheTable(
        _ table: FITTable,
        image: UEFIImage?,
        reader: ImageReader
    ) -> RoomAfterTheTable {
        let end = table.range.upperBound
        let needed = end..<(end + FITEntry.size)
        guard reader.has(needed) else { return .taken("past the end of the image") }
        if reader.isFilled(needed, with: 0xFF) { return .free }

        guard let image, let node = image.nodes(containing: end).last else {
            return .taken("bytes belonging to nothing this tool can name")
        }
        switch node.kind {
        case .freeSpace, .padding, .nonUEFIData:
            guard node.isErased, node.range.upperBound >= needed.upperBound else { break }
            // Never written to, whatever the erase byte of its volume is.
            return .free
        default:
            break
        }
        return .taken("inside \(node.name) at 0x"
            + String(node.range.lowerBound, radix: 16, uppercase: true))
    }

    private enum RoomAfterTheTable {
        case free
        case taken(String)
    }

    /// The row whose component is for this processor.
    ///
    /// One CPUID can have several rows, one per platform mask, and they are not
    /// interchangeable: a microcode for platform 02 does not belong in the row
    /// that names platform 22's. So an exact mask wins, an overlapping one is
    /// next, and only if neither is there does the first row for the CPUID
    /// answer.
    private static func rowNaming(
        _ cpuid: UInt32,
        matching header: MicrocodeHeader,
        in table: FITTable
    ) -> FITRow? {
        let candidates = table.rows.filter { row in
            guard case .microcode(let found) = row.target else { return false }
            return found.processorSignature == cpuid
        }
        func component(_ row: FITRow) -> MicrocodeHeader? {
            guard case .microcode(let found) = row.target else { return nil }
            return found
        }
        return candidates.first { component($0)?.platformIDs == header.platformIDs }
            ?? candidates.first { (component($0)?.platformIDs ?? 0) & header.platformIDs != 0 }
            ?? candidates.first
    }

    private static func addingNewRow(
        _ bytes: [UInt8],
        for header: MicrocodeHeader,
        to table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64
    ) -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        let placement: FITPlacement
        switch self.placement(forSize: UInt64(header.totalSize), table: table, image: image,
                              reader: reader, addressDiff: addressDiff) {
        case .success(let found): placement = found
        case .failure(let problem): return .failure(problem)
        }
        return addMicrocode(bytes, at: placement, to: table, image: image, in: reader)
            .map { transaction in
            let index = (table.rows.lastIndex { $0.entry.type == FIT.microcodeType } ?? 0) + 1
            var transaction = transaction
            // A component placed behind the file the run lives in belongs
            // inside it, not loose in the volume's free space.
            let growth = fileGrowth(
                toCover: placement.range.upperBound,
                around: table.rows.compactMap { row -> UInt64? in
                    guard case .microcode(let header) = row.target else { return nil }
                    return header.offset
                }.max() ?? placement.range.lowerBound,
                image: image, reader: reader
            )
            if let growth { transaction.writes.append(growth.write) }
            return (
                withContainerRepairs(
                    transaction, image: image, reader: reader, grownFile: growth?.grown
                ),
                FITEditOutcome(
                    kind: .added, range: placement.range, entryIndex: index, replaced: nil
                )
            )
        }
    }

    /// Adds a microcode entry: the component, and the table rebuilt around a
    /// new row (§9.2 steps 2 to 7).
    public static func addMicrocode(
        _ component: [UInt8],
        at placement: FITPlacement,
        to table: FITTable,
        image: UEFIImage? = nil,
        in reader: ImageReader
    ) -> Result<ToolTransaction, FITEditProblem> {
        guard var rows = rowBytes(of: table, in: reader) else { return .failure(.noSuchEntry) }
        let row = entryBytes(address: placement.address)

        // Rows do not decrease in type (§3), so a microcode row goes after the
        // last one there is.
        let insertion = (rows.lastIndex { type(of: $0) == FIT.microcodeType } ?? 0) + 1
        switch roomAfterTheTable(table, image: image, reader: reader) {
        case .free:
            // The table grows by a row and the header's count goes up with it
            // (§9.2 step 6), which needs the sixteen bytes after the table to
            // be free.
            rows.insert(row, at: insertion)
        case .taken(let what):
            guard let slot = rows.indices.first(where: {
                $0 >= insertion && type(of: rows[$0]) == FIT.emptyType
            }) else { return .failure(.theTableCannotGrow(after: what)) }
            // Nowhere to grow into, so an empty slot is eaten instead (§9.4).
            // The table keeps its length and the count stays as it was — the
            // fallback rather than the first choice, because a slot in the
            // middle of the run is not where a reader expects the spare room.
            rows.remove(at: slot)
            rows.insert(row, at: insertion)
        }

        return .success(ToolTransaction(
            name: "Add Microcode",
            writes: [
                ToolTransaction.Write(offset: placement.range.lowerBound, bytes: component),
                ToolTransaction.Write(
                    offset: table.range.lowerBound,
                    bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
                )
            ]
        ))
    }

    /// Takes an entry out, body and all (§10).
    ///
    /// A microcode run is one block, and a hole in the middle of it is not what
    /// a bench wants back: the component's bytes go, everything after it in the
    /// run moves up into the space, the rows that name those components are
    /// repointed, and the bytes the move frees at the end are erased. The
    /// table loses the row and the header's count comes down with it.
    ///
    /// A component only moves if everything between it and the one before it is
    /// erased — so nothing that is not part of the run can be written over, and
    /// the compaction stops at the first thing that is.
    ///
    /// Moving a component changes its address, which anything outside the FIT
    /// that named it will not know about. Boot Guard is the one that matters,
    /// and this tool cannot read its ranges (`Design/TODO.md`). What it *can*
    /// put right it does: a run inside an FFS file leaves that file's checksums
    /// describing what used to be there, and those are recomputed into the same
    /// transaction.
    public static func removeEntry(
        _ index: Int,
        from table: FITTable,
        image: UEFIImage?,
        in reader: ImageReader,
        addressDiff: UInt64
    ) -> Result<(ToolTransaction, FITRemovalOutcome), FITEditProblem> {
        guard index > 0 else { return .failure(.cannotRemoveTheHeader) }
        guard var rows = rowBytes(of: table, in: reader), index < rows.count,
              index < table.rows.count
        else { return .failure(.noSuchEntry) }
        if type(of: rows[index]) == FIT.microcodeType,
           rows.filter({ type(of: $0) == FIT.microcodeType }).count == 1 {
            return .failure(.cannotRemoveTheLastMicrocode)
        }

        var writes: [ToolTransaction.Write] = []
        var moved = 0
        var erased: Range<UInt64>?

        // Only a microcode's body is compacted: the extent of anything else a
        // row can point at — an ACM, a policy — is not something this tool
        // knows, and moving bytes it cannot measure is not a thing to guess at.
        if case .microcode(let removed) = table.rows[index].target {
            // Dropping a component is re-laying the run with nothing in its
            // place, which is the same operation as replacing it with something
            // of another size.
            switch relay(replacing: removed, with: nil, in: table, image: image, reader: reader) {
            case .failure(let problem):
                return .failure(problem)
            case .success(let plan):
                moved = plan.moves.count
                erased = plan.erased
                writes.append(plan.write)
                if let growth = plan.growth { writes.append(growth.write) }
                for move in plan.moves {
                    writeAddress(move.newOffset + addressDiff, into: &rows[move.rowIndex])
                }
            }
        }

        rows.remove(at: index)
        // The sixteen bytes the table gives up are erased behind it, so no
        // stale row is left for another parser to trip over (§10 step 3).
        let assembled = assemble(rows, checksumIsChecked: table.checksumIsChecked)
            + [UInt8](repeating: 0xFF, count: Int(FITEntry.size))
        writes.append(ToolTransaction.Write(offset: table.range.lowerBound, bytes: assembled))

        return .success((
            withContainerRepairs(
                ToolTransaction(name: "Remove FIT Entry", writes: writes),
                image: image, reader: reader
            ),
            FITRemovalOutcome(entryIndex: index, moved: moved, erased: erased)
        ))
    }

    /// The run of microcodes, laid out again from where one of them was.
    private struct Relayout {
        /// The whole re-laid stretch as one write: what goes in the hole, the
        /// components behind it packed and aligned, and erase bytes for
        /// anything the move left over.
        var write: ToolTransaction.Write
        var moves: [(rowIndex: Int, newOffset: UInt64)]
        var erased: Range<UInt64>?
        /// The file the run lives in, grown to cover a run that got longer.
        var growth: (write: ToolTransaction.Write, grown: UEFINode)?
    }

    /// The file the run lives in, grown to cover `end`.
    ///
    /// A component placed behind that file would otherwise sit loose in the
    /// volume's free space, where the volume's own walk meets it as bytes
    /// nobody claimed — which is what UEFITool draws as "non-UEFI data" and
    /// what a rebuild would not know to keep. Growing the file puts it inside a
    /// structure, and the volume's free space shrinks by exactly as much
    /// without anything having to record it: free space is whatever the walk
    /// finds erased after the last file (§5.8).
    ///
    /// Only into space that belongs to nothing: the bytes between the file's
    /// end and `end` have to be the volume's free space or erased padding, and
    /// erased. Anything else there — another file, most of all — and the file
    /// stays the size it is.
    private static func fileGrowth(
        toCover end: UInt64,
        around offset: UInt64,
        image: UEFIImage?,
        reader: ImageReader
    ) -> (write: ToolTransaction.Write, grown: UEFINode)? {
        guard let image else { return nil }
        let chain = image.nodes(containing: offset)
        guard let file = chain.last(where: { $0.kind == .file }),
              end > file.range.upperBound
        else { return nil }

        // Everything from the file's end to `end` must belong to nothing.
        guard let parent = chain.last(where: { $0.children.contains { $0.id == file.id } })
                ?? chain.dropLast().last
        else { return nil }
        var covered = file.range.upperBound
        for child in parent.children where child.range.lowerBound >= file.range.upperBound {
            guard child.range.lowerBound == covered, isSpare(child, reader) else { break }
            covered = child.range.upperBound
        }
        guard covered >= end, reader.isFilled(file.range.upperBound..<end, with: 0xFF) else {
            return nil
        }

        let size = end - file.header.lowerBound
        guard var header = reader.bytes(file.header) else { return nil }
        // An FFSv3 large file's header is 0x20 bytes where a plain one is 0x18
        // (§5.1), and the size it uses is the 64-bit field behind the base.
        if header.count >= 0x20 {
            // FFSv3 keeps a large file's size in a field of its own (§5.2).
            for index in 0..<8 {
                header[0x18 + index] = UInt8(truncatingIfNeeded: size >> (8 * index))
            }
        } else {
            guard size <= 0xFF_FFFF else { return nil }
            for index in 0..<3 {
                header[0x14 + index] = UInt8(truncatingIfNeeded: size >> (8 * index))
            }
        }

        var grown = file
        grown.body = file.body.lowerBound..<end
        // The checksums that go with the new size are the container repair's,
        // computed over the image as this transaction will leave it.
        return (ToolTransaction.Write(offset: file.header.lowerBound, bytes: header), grown)
    }

    /// The checksums a change breaks on its way out, recomputed and folded into
    /// the same transaction.
    ///
    /// Microcode does not always live in a raw region: on plenty of boards the
    /// run sits inside an FFS file, and then changing those bytes leaves that
    /// file's own `IntegrityCheck` describing what used to be there (§5.4). The
    /// repairs are computed over the image *as this transaction will leave it*
    /// — a checksum describes bytes as they will be, not as they are — which is
    /// what `OverlayByteSource` is for.
    ///
    /// A volume needs nothing: its checksum covers its own header and not its
    /// body (§3.3), which is the one mercy in this format.
    private static func withContainerRepairs(
        _ transaction: ToolTransaction,
        image: UEFIImage?,
        reader: ImageReader,
        grownFile: UEFINode? = nil
    ) -> ToolTransaction {
        guard let image else { return transaction }
        let after = ImageReader(OverlayByteSource(
            base: reader.source,
            patches: transaction.writes.map {
                OverlayByteSource.Patch(offset: $0.offset, bytes: $0.bytes)
            }
        ))

        var repaired = transaction
        var done: Set<NodeID> = []
        for write in transaction.writes {
            let chain = image.nodes(containing: write.offset)
            guard var file = chain.last(where: { $0.kind == .file }), !done.contains(file.id)
            else { continue }
            done.insert(file.id)
            // A file that grew is checked over its new extent, not the one the
            // parse found.
            if let grownFile, grownFile.id == file.id { file = grownFile }
            let revision = chain.last { $0.kind == .volume }?.subtype ?? 2
            for repair in UEFIChecksums.repairs(for: file, volumeRevision: revision, in: after) {
                let range = repair.offset..<(repair.offset + UInt64(repair.bytes.count))
                if let index = repaired.writes.firstIndex(where: {
                    $0.offset <= range.lowerBound
                        && range.upperBound <= $0.offset + UInt64($0.bytes.count)
                }) {
                    // The repair falls inside a write this transaction is
                    // already making — a file header that grew, most of all —
                    // so it is patched into that write rather than added beside
                    // it, which a transaction refuses as overlapping.
                    let at = Int(range.lowerBound - repaired.writes[index].offset)
                    repaired.writes[index].bytes.replaceSubrange(
                        at..<(at + repair.bytes.count), with: repair.bytes
                    )
                } else {
                    repaired.writes.append(
                        ToolTransaction.Write(offset: repair.offset, bytes: repair.bytes)
                    )
                }
            }
        }
        return repaired
    }

    /// Re-lays the run from `removed`'s offset, putting `replacement` where it
    /// was — or nothing, which is what a removal is.
    ///
    /// A component only moves if everything between it and the one before it is
    /// erased, so nothing that is not part of the run can be written over, and
    /// the walk stops at the first thing that is not. Growing is bounded by
    /// whatever element holds the run: a component that would push the last one
    /// past the end of its padding, its region or its volume is refused rather
    /// than written over the next structure along.
    private static func relay(
        replacing removed: MicrocodeHeader,
        with replacement: [UInt8]?,
        in table: FITTable,
        image: UEFIImage?,
        reader: ImageReader
    ) -> Result<Relayout, FITEditProblem> {
        let start = removed.offset
        var following: [(row: Int, header: MicrocodeHeader)] = []
        for row in table.rows {
            guard case .microcode(let header) = row.target, header.offset > start else { continue }
            following.append((row.entry.index, header))
        }
        following.sort { $0.header.offset < $1.header.offset }

        var accepted: [(row: Int, header: MicrocodeHeader)] = []
        var boundary = removed.range.upperBound
        for item in following {
            guard item.header.offset >= boundary,
                  item.header.offset == boundary
                      || reader.isFilled(boundary..<item.header.offset, with: 0xFF)
            else { break }
            accepted.append(item)
            boundary = item.header.range.upperBound
        }

        var payload = replacement ?? []
        var moves: [(rowIndex: Int, newOffset: UInt64)] = []
        var next = start + UInt64(payload.count)
        for item in accepted {
            // Every FIT address is aligned to sixteen (§8.9), so a component
            // whose size is not a multiple of it leaves a gap in front of the
            // next one.
            let at = alignUp(next, to: 16) ?? next
            guard let bytes = reader.bytes(item.header.range) else { break }
            payload += [UInt8](repeating: 0xFF, count: Int(at - next))
            payload += bytes
            if at != item.header.offset { moves.append((item.row, at)) }
            next = at + UInt64(item.header.totalSize)
        }

        let oldEnd = accepted.last?.header.range.upperBound ?? removed.range.upperBound
        var growth: (write: ToolTransaction.Write, grown: UEFINode)?
        if next > oldEnd {
            // The run grew. What it grew into has to be free and erased, and
            // inside the element that holds it — or, where the element is a
            // file with free space directly behind it, the file grows to cover
            // the difference and the run stays inside a structure.
            let area = spareArea(around: start, image: image, reader: reader).range
            guard next <= reader.count, reader.isFilled(oldEnd..<next, with: 0xFF) else {
                return .failure(.theRunCannotGrow(needed: next - oldEnd))
            }
            if next > area.upperBound {
                guard let found = fileGrowth(
                    toCover: next, around: start, image: image, reader: reader
                ) else { return .failure(.theRunCannotGrow(needed: next - area.upperBound)) }
                growth = found
            }
        } else if oldEnd > next {
            payload += [UInt8](repeating: 0xFF, count: Int(oldEnd - next))
        }
        return .success(Relayout(
            write: ToolTransaction.Write(offset: start, bytes: payload),
            moves: moves,
            erased: oldEnd > next ? next..<oldEnd : nil,
            growth: growth
        ))
    }

    private static func writeAddress(_ address: UInt64, into row: inout [UInt8]) {
        for index in 0..<8 {
            row[index] = UInt8(truncatingIfNeeded: address >> (8 * index))
        }
    }

    // MARK: - Rows as bytes

    /// The table as sixteen-byte rows, read back rather than rebuilt from what
    /// was parsed: a row carries fields this tool does not model, and rewriting
    /// one from a struct would quietly drop them.
    private static func rowBytes(of table: FITTable, in reader: ImageReader) -> [[UInt8]]? {
        guard let bytes = reader.bytes(table.range), bytes.count % Int(FITEntry.size) == 0
        else { return nil }
        return stride(from: 0, to: bytes.count, by: Int(FITEntry.size)).map {
            Array(bytes[$0..<($0 + Int(FITEntry.size))])
        }
    }

    private static func type(of row: [UInt8]) -> UInt8 { row[0x0E] & 0x7F }

    /// The header's count and the checksum, which are the two fields that
    /// depend on every other byte of the table (§4, §5).
    private static func assemble(_ rows: [[UInt8]], checksumIsChecked: Bool) -> [UInt8] {
        var rows = rows
        let count = UInt32(rows.count)
        for index in 0..<3 {
            rows[0][0x08 + index] = UInt8(truncatingIfNeeded: count >> (8 * index))
        }
        rows[0][0x0F] = 0
        var bytes = rows.flatMap { $0 }
        if checksumIsChecked {
            bytes[0x0F] = 0 &- Checksums.sum8(bytes)
        }
        return bytes
    }

    /// §9.2 step 5, field for field.
    private static func entryBytes(address: UInt64) -> [UInt8] {
        var row = (0..<8).map { UInt8(truncatingIfNeeded: address >> (8 * $0)) }
        row += [0, 0, 0]                 // Size — unused for microcode (§7.1)
        row += [0]                       // Reserved
        row += [0x00, 0x01]              // Version 0x0100
        row += [FIT.microcodeType]       // Type, with ChecksumValid clear
        row += [0]                       // Checksum
        return row
    }

    /// §9.4: an address of zero, no size, version 0x0100, type 0x7F.
    private static func emptySlotBytes() -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + [0x00, 0x01, FIT.emptyType, 0]
    }
}
