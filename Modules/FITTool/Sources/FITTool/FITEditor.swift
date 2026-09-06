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

    /// The table has no empty slot and the bytes after it are not free, so it
    /// cannot grow (§9.1). Carries what is in the way, because "no empty slot"
    /// on its own leaves nobody anywhere to go.
    case theTableCannotGrow(after: String)
    /// The run would have to grow further than there is room for. Carries how
    /// much more it needs and what it would have to grow through — a refusal
    /// that says neither leaves the user with nowhere to go.
    case theRunCannotGrow(needed: UInt64, inside: String)
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

        case .theTableCannotGrow(let after):
            return "The table has no empty slot, and the sixteen bytes after it are not free —"
                + " they are " + after + "."

        case .theRunCannotGrow(let needed, let inside):
            return "The microcode run needs 0x" + String(needed, radix: 16, uppercase: true)
                + " more bytes than are free after it, in " + inside + "."
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

    /// Whether `range` is filler rather than content.
    ///
    /// Erased flash reads `0xFF`, a volume erased with polarity 0 reads `0x00`
    /// (§3.5) — and the tools that build images pad with whatever they like: a
    /// file holding a FIT table padded to its end with `0x20` is a real one.
    /// The specification says nothing about what unused space *inside a file*
    /// has to contain; §5.8 describes only a volume's free space.
    ///
    /// So what marks filler is not the byte but the uniformity: one value,
    /// unbroken, from here to the end of the element that holds it. Sixteen
    /// identical bytes in the middle of content would not pass that, and a
    /// vendor's padding does.
    static func isFree(
        _ range: Range<UInt64>,
        upTo end: UInt64,
        in reader: ImageReader
    ) -> Bool {
        guard !range.isEmpty else { return false }
        // Erased flash, which needs no argument.
        if reader.isFilled(range, with: 0xFF) { return true }
        // Or a fill: one value, unbroken, from here to the end of the element
        // that holds it. Sixteen identical bytes in the middle of content would
        // not pass that; a vendor's padding does.
        guard range.upperBound <= end, let byte = reader.uint8(at: range.lowerBound)
        else { return false }
        return reader.isFilled(range.lowerBound..<end, with: byte)
    }

    /// What this image pads with, at `offset`.
    ///
    /// Tidying up after an edit means leaving the same fill the image already
    /// uses: sixteen bytes of `0xFF` in the middle of a `0x20`-padded file are
    /// litter of a new kind, and they break the uniformity the *next* edit
    /// reads as free space.
    static func fillByte(at offset: UInt64, upTo end: UInt64, in reader: ImageReader) -> UInt8 {
        guard offset < end, let byte = reader.uint8(at: offset),
              reader.isFilled(offset..<end, with: byte)
        else { return 0xFF }
        return byte
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

        let run = self.run(in: table, reader: reader)
        guard let target = run.firstIndex(where: {
            guard case .existing(_, let header) = $0 else { return false }
            return header.offset == old.offset
        }), case .existing(_, let first) = run[0], case .existing(_, let last) = run[run.count - 1]
        else { return .failure(.noSuchEntry) }
        var items = run
        items[target] = .fresh(bytes)

        switch relayRun(items, from: first.offset, oldEnd: last.range.upperBound,
                        image: image, reader: reader) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let plan):
            var writes = [plan.write].compactMap { $0 }
            if let growth = plan.growth { writes.append(growth.write) }
            let ownRowMoved = plan.freshOffset != nil && plan.freshOffset != old.offset
            if !plan.moves.isEmpty || ownRowMoved {
                // Only when something moved: a transaction that writes the
                // table back unchanged is a step in the undo history that
                // undoes nothing.
                guard var rows = rowBytes(of: table, in: reader) else {
                    return .failure(.noSuchEntry)
                }
                for move in plan.moves {
                    writeAddress(move.newOffset + addressDiff, into: &rows[move.rowIndex])
                }
                if let fresh = plan.freshOffset {
                    writeAddress(fresh + addressDiff, into: &rows[row.entry.index])
                }
                writes.append(ToolTransaction.Write(
                    offset: table.range.lowerBound,
                    bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
                ))
            }
            let landed = plan.freshOffset ?? old.offset
            return .success((
                withContainerRepairs(
                    ToolTransaction(name: "Replace Microcode", writes: writes),
                    image: image, reader: reader, grownFile: plan.growth?.grown
                ),
                FITEditOutcome(
                    kind: .replaced,
                    range: landed..<(landed + UInt64(header.totalSize)),
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
        guard reader.has(needed), let bytes = reader.bytes(needed) else {
            return .taken("past the end of the image")
        }
        func whatIsThere() -> RoomAfterTheTable {
            let head = bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            return .taken("\(head)… at 0x" + String(end, radix: 16, uppercase: true))
        }

        // Whose are they? Bytes in the same element as the table are nobody
        // else's — the table's own file has room in it, and the checksums that
        // covers are put right with everything else. Free space and padding
        // belong to nobody at all. Anything else is another structure.
        guard let image else {
            return reader.isFilled(needed, with: 0xFF) ? .free : whatIsThere()
        }
        let mine = image.innermostNode(containing: table.range.lowerBound)
        guard let theirs = image.innermostNode(containing: end) else {
            return reader.isFilled(needed, with: 0xFF) ? .free : whatIsThere()
        }
        let sameElement = theirs.id == mine?.id
        switch theirs.kind {
        case .freeSpace, .padding, .nonUEFIData:
            break
        default:
            guard sameElement else {
                return .taken("inside \(theirs.name) at 0x"
                    + String(theirs.range.lowerBound, radix: 16, uppercase: true))
            }
        }
        // Filler to the end of whatever holds it, whatever byte the tool that
        // built the image chose.
        return isFree(needed, upTo: theirs.range.upperBound, in: reader)
            ? .free
            : whatIsThere()
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
        let run = self.run(in: table, reader: reader)
        guard case .existing(_, let first)? = run.first,
              case .existing(_, let last)? = run.last
        else { return .failure(.noMicrocodeToFollow) }

        // The run is laid out again with the new component on the end, so a
        // gap an earlier removal left is used rather than stepped over.
        let plan: Relayout
        switch relayRun(run + [.fresh(bytes)], from: first.offset,
                        oldEnd: last.range.upperBound, image: image, reader: reader) {
        case .success(let found): plan = found
        case .failure(let problem): return .failure(problem)
        }
        guard let landed = plan.freshOffset else { return .failure(.noSuchEntry) }

        guard var rows = rowBytes(of: table, in: reader) else { return .failure(.noSuchEntry) }
        for move in plan.moves {
            writeAddress(move.newOffset + addressDiff, into: &rows[move.rowIndex])
        }

        // Rows do not decrease in type (§3), so a microcode row goes after the
        // last one there is.
        let insertion = (rows.lastIndex { type(of: $0) == FIT.microcodeType } ?? 0) + 1
        switch roomAfterTheTable(table, image: image, reader: reader) {
        case .free:
            // The table grows by a row and the header's count goes up with it
            // (§9.2 step 6), which needs the sixteen bytes after the table to
            // be free.
            rows.insert(entryBytes(address: landed + addressDiff), at: insertion)
        case .taken(let what):
            guard let slot = rows.indices.first(where: {
                $0 >= insertion && type(of: rows[$0]) == FIT.emptyType
            }) else { return .failure(.theTableCannotGrow(after: what)) }
            // Nowhere to grow into, so an empty slot is eaten instead (§9.4).
            // The table keeps its length and the count stays as it was — the
            // fallback rather than the first choice, because a slot in the
            // middle of the run is not where a reader expects the spare room.
            rows.remove(at: slot)
            rows.insert(entryBytes(address: landed + addressDiff), at: insertion)
        }

        var writes = [plan.write].compactMap { $0 }
        if let growth = plan.growth { writes.append(growth.write) }
        writes.append(ToolTransaction.Write(
            offset: table.range.lowerBound,
            bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
        ))
        return .success((
            withContainerRepairs(
                ToolTransaction(name: "Add Microcode", writes: writes),
                image: image, reader: reader, grownFile: plan.growth?.grown
            ),
            FITEditOutcome(
                kind: .added,
                range: landed..<(landed + UInt64(header.totalSize)),
                entryIndex: insertion,
                replaced: nil,
                moved: plan.moves.count
            )
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
            let run = self.run(in: table, reader: reader)
            guard case .existing(_, let first)? = run.first,
                  case .existing(_, let last)? = run.last
            else { return .failure(.noSuchEntry) }
            let items = run.filter {
                guard case .existing(_, let header) = $0 else { return true }
                return header.offset != removed.offset
            }
            switch relayRun(items, from: first.offset, oldEnd: last.range.upperBound,
                            image: image, reader: reader) {
            case .failure(let problem):
                return .failure(problem)
            case .success(let plan):
                moved = plan.moves.count
                erased = plan.erased
                if let write = plan.write { writes.append(write) }
                if let growth = plan.growth { writes.append(growth.write) }
                for move in plan.moves {
                    writeAddress(move.newOffset + addressDiff, into: &rows[move.rowIndex])
                }
            }
        }

        rows.remove(at: index)
        // The sixteen bytes the table gives up are wiped behind it, so no stale
        // row is left for another parser to trip over (§10 step 3) — with the
        // fill the file the table sits in already uses, so the tail stays the
        // one uniform stretch that the next edit can read as free.
        let element = image?.innermostNode(containing: table.range.lowerBound)?.range
        let assembled = assemble(rows, checksumIsChecked: table.checksumIsChecked)
            + [UInt8](
                repeating: fillByte(
                    at: table.range.upperBound,
                    upTo: element?.upperBound ?? reader.count,
                    in: reader
                ),
                count: Int(FITEntry.size)
            )
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
        /// Nil when the layout comes out byte for byte what is already there.
        var write: ToolTransaction.Write?
        var moves: [(rowIndex: Int, newOffset: UInt64)]
        var erased: Range<UInt64>?
        /// The file the run lives in, grown to cover a run that got longer.
        var growth: (write: ToolTransaction.Write, grown: UEFINode)?
        /// Where the component that was not in the image yet ended up.
        var freshOffset: UInt64?
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
        guard covered >= end,
              isFree(file.range.upperBound..<end, upTo: covered, in: reader)
        else { return nil }

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

    /// One thing to lay down in the run.
    private enum RunItem {
        /// A component already in the image, and the row that names it.
        case existing(row: Int, header: MicrocodeHeader)
        /// A component that is not in the image yet.
        case fresh([UInt8])
    }

    /// The microcodes of the run, in offset order, ending at the last one the
    /// table names.
    ///
    /// A component belongs to the run only if everything between it and the one
    /// before it is erased. That is what keeps the re-layout from writing over
    /// something that merely happens to sit between two microcodes.
    private static func run(in table: FITTable, reader: ImageReader) -> [RunItem] {
        var components: [(row: Int, header: MicrocodeHeader)] = []
        for row in table.rows {
            guard case .microcode(let header) = row.target else { continue }
            components.append((row.entry.index, header))
        }
        components.sort { $0.header.offset < $1.header.offset }

        // Backwards from the last, so the run is the block the newest microcode
        // is in rather than whichever block comes first in the image.
        var run: [(row: Int, header: MicrocodeHeader)] = []
        for item in components.reversed() {
            if let first = run.first {
                let gap = item.header.range.upperBound..<first.header.offset
                guard gap.lowerBound <= gap.upperBound,
                      gap.isEmpty || reader.isFilled(gap, with: 0xFF)
                else { break }
            }
            run.insert(item, at: 0)
        }
        return run.map { .existing(row: $0.row, header: $0.header) }
    }

    /// Lays `items` down from `start`, packed and sixteen-byte aligned, and
    /// erases whatever the layout leaves over up to `oldEnd`.
    ///
    /// This is the one operation behind all three edits: removing drops an item
    /// from the list, replacing swaps one, adding appends one. What comes out
    /// is a run with no holes in it — which is what a microcode run is, and why
    /// adding after a removal does not leave the gap the removal made.
    ///
    /// Growing is bounded by the element that holds the run. Where that element
    /// is a file with free space directly behind it, the file grows to cover
    /// the difference and the run stays inside a structure.
    private static func relayRun(
        _ items: [RunItem],
        from start: UInt64,
        oldEnd: UInt64,
        image: UEFIImage?,
        reader: ImageReader
    ) -> Result<Relayout, FITEditProblem> {
        var payload: [UInt8] = []
        var moves: [(rowIndex: Int, newOffset: UInt64)] = []
        var freshOffset: UInt64?
        var next = start
        // The same fill the run already sits in, for the few bytes alignment
        // leaves between components.
        let alignmentFill = fillByte(
            at: oldEnd,
            upTo: spareArea(around: start, image: image, reader: reader).range.upperBound,
            in: reader
        )

        for item in items {
            // Every FIT address is aligned to sixteen (§8.9), so a component
            // whose size is not a multiple of it leaves a gap in front of the
            // next one.
            let at = alignUp(next, to: 16) ?? next
            payload += [UInt8](repeating: alignmentFill, count: Int(at - next))
            switch item {
            case .existing(let row, let header):
                guard let bytes = reader.bytes(header.range) else { break }
                payload += bytes
                if at != header.offset { moves.append((row, at)) }
                next = at + UInt64(header.totalSize)
            case .fresh(let bytes):
                payload += bytes
                freshOffset = at
                next = at + UInt64(bytes.count)
            }
        }

        var growth: (write: ToolTransaction.Write, grown: UEFINode)?
        if next > oldEnd {
            let area = spareArea(around: start, image: image, reader: reader)
            let where_ = "\(area.name) at 0x"
                + String(area.range.lowerBound, radix: 16, uppercase: true) + "–0x"
                + String(area.range.upperBound, radix: 16, uppercase: true)
            guard next <= reader.count,
                  isFree(oldEnd..<next, upTo: area.range.upperBound, in: reader)
            else {
                return .failure(.theRunCannotGrow(needed: next - oldEnd, inside: where_))
            }
            if next > area.range.upperBound {
                guard let found = fileGrowth(
                    toCover: next, around: start, image: image, reader: reader
                ) else {
                    return .failure(.theRunCannotGrow(
                        needed: next - area.range.upperBound, inside: where_
                    ))
                }
                growth = found
            }
        } else if oldEnd > next {
            // Tidied with the fill this image uses, not with a byte of our own
            // choosing.
            let area = spareArea(around: start, image: image, reader: reader).range
            payload += [UInt8](
                repeating: fillByte(at: oldEnd, upTo: area.upperBound, in: reader),
                count: Int(oldEnd - next)
            )
        }
        // Only the part that differs is written. A run whose first components
        // do not move must not be rewritten with the bytes it already holds:
        // the dump would colour every one of them as changed, and the undo step
        // would take back more than the edit did.
        var write: ToolTransaction.Write? = ToolTransaction.Write(offset: start, bytes: payload)
        if let current = reader.bytes(start..<(start + UInt64(payload.count))) {
            // Both ends: a replacement in the middle of a run leaves the
            // components in front of it and behind it exactly as they were.
            var first = 0
            while first < payload.count, payload[first] == current[first] { first += 1 }
            if first == payload.count {
                write = nil
            } else {
                var last = payload.count - 1
                while last > first, payload[last] == current[last] { last -= 1 }
                write = ToolTransaction.Write(
                    offset: start + UInt64(first), bytes: Array(payload[first...last])
                )
            }
        }
        return .success(Relayout(
            write: write,
            moves: moves,
            erased: oldEnd > next ? next..<oldEnd : nil,
            growth: growth,
            freshOffset: freshOffset
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
