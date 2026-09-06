import Foundation

/// Everything one action of a tool-module writes, as one thing.
///
/// A transaction is the unit of undo, and it is a list rather than a single
/// write because the work has that shape. Adding a microcode entry to a FIT
/// table (`Design/UEFI/FIT_TABLE_FORMAT.md` §9.2) is four writes that are not
/// next to each other — the component, the table entry, the entry count in the
/// header, and the header's checksum — and an image carrying three of the four
/// is worse than an image carrying none of them. So they land together, they
/// undo together, and they are named once for both.
///
/// Overwrite is the only write here, which is less of a restriction than it
/// reads as: a dump's size is the flash chip's size, and the operations that
/// change it — insert, delete — are the ones the app already warns about for
/// typing. When a tool-module needs one, it arrives under that same rule rather
/// than as a second kind of transaction.
public struct ToolTransaction: Equatable, Sendable {
    /// What the user is about to be able to undo — "Add Microcode", not "Write
    /// 16 bytes". It becomes the Edit menu's `Undo <name>`, so it is written
    /// from the user's side of the action.
    public var name: String
    public var writes: [Write]

    /// Bytes to put at an offset. The length is the bytes' length: a write
    /// replaces exactly as much as it carries.
    public struct Write: Equatable, Sendable {
        public var offset: UInt64
        public var bytes: [UInt8]

        public init(offset: UInt64, bytes: [UInt8]) {
            self.offset = offset
            self.bytes = bytes
        }

        /// What this write covers.
        public var range: Range<UInt64> { offset..<(offset &+ UInt64(bytes.count)) }
    }

    public init(name: String, writes: [Write]) {
        self.name = name
        self.writes = writes
    }

    public init(name: String, offset: UInt64, bytes: [UInt8]) {
        self.init(name: name, writes: [Write(offset: offset, bytes: bytes)])
    }

    /// From the first byte written to the last — what the dump has to redraw,
    /// and what a tool-module's own re-read can be narrowed to. Nil only for a
    /// transaction with nothing in it.
    public var span: Range<UInt64>? {
        guard let lower = writes.map(\.range.lowerBound).min(),
              let upper = writes.map(\.range.upperBound).max() else { return nil }
        return lower..<upper
    }

    /// The transaction as it will be applied, or an error saying why it cannot
    /// be — checked before anything is written, because the point of a
    /// transaction is that the file never sees half of one.
    ///
    /// What it repairs: the writes come back sorted by offset, and writes that
    /// touch end to end are merged, so the host applies one range where a
    /// tool-module emitted four adjacent ones.
    ///
    /// What it refuses:
    ///
    /// - **Two writes over the same byte.** Which of them wins is not something
    ///   an ordering rule should decide quietly — it means the tool-module
    ///   computed an offset wrong, which is precisely the class of mistake
    ///   §11 of the FIT document is about (one hex digit out, silently written
    ///   into free space).
    /// - **A write of no bytes**, which asks for nothing and usually means a
    ///   length was computed as zero.
    /// - **No writes at all**, and a **blank name**: a step the user can undo
    ///   has to say what it was.
    ///
    /// Bounds are not checked here — the file's size belongs to the host, and
    /// it checks them when it applies (stage 6).
    public func validated() throws -> ToolTransaction {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolTransactionError.unnamed
        }
        guard !writes.isEmpty else { throw ToolTransactionError.noWrites }
        if let empty = writes.first(where: { $0.bytes.isEmpty }) {
            throw ToolTransactionError.emptyWrite(at: empty.offset)
        }

        let sorted = writes.sorted { $0.offset < $1.offset }
        var merged: [Write] = []
        for write in sorted {
            guard var last = merged.last else { merged.append(write); continue }
            if write.offset < last.range.upperBound {
                throw ToolTransactionError.overlappingWrites(at: write.offset)
            }
            if write.offset == last.range.upperBound {
                last.bytes.append(contentsOf: write.bytes)
                merged[merged.count - 1] = last
            } else {
                merged.append(write)
            }
        }
        return ToolTransaction(name: name, writes: merged)
    }
}

/// Why a transaction cannot be applied. Each case names the offset it is about
/// where there is one, because "overlapping writes" without an address is a
/// message a tool-module's author cannot act on.
public enum ToolTransactionError: Error, Equatable {
    case unnamed
    case noWrites
    case emptyWrite(at: UInt64)
    case overlappingWrites(at: UInt64)
}
