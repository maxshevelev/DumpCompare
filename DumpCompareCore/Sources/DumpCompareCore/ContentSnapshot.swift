import Foundation

/// An immutable view of what an `EditOverlayStorage` held at one moment — the
/// bytes a duplicated document reads (§23).
///
/// It is the same three parts the live overlay reads through, frozen: the base
/// it was layered over, a copy of the append-only buffer, and a copy of the
/// piece list that arranges them. Nothing here can be mutated, so the copy's
/// content cannot drift from the bytes the snapshot was taken from, and two
/// documents can read it at once from any thread without a lock.
///
/// Taking one copies no bytes. The piece list and the add buffer are Swift
/// arrays, so they share their storage with the overlay's until one side is
/// written — the overlay's next edit pays for the divergence, and the add buffer
/// is bounded by its budget (`EditOverlayStorage.Budgets.maxAddedBytes`). The
/// base is shared outright, which is only safe because an overlay never writes
/// to its base: see `EditOverlayStorage.contentSnapshot(scratch:)` for what it
/// does about a base that something *outside* the overlay can write.
///
/// Not a `FileBackedStorage`, deliberately: an overlay built on a snapshot
/// therefore treats its base as private (immutable, shareable as it is) and
/// keeps no `originalURL`, so saving the copy always writes its full content
/// rather than patching a file the copy never came from.
final class ContentSnapshot: ByteStorage, @unchecked Sendable {
    private let base: any ByteStorage
    private let added: [UInt8]
    private let table: PieceTable

    let size: UInt64

    init(base: any ByteStorage, added: [UInt8], table: PieceTable) {
        self.base = base
        self.added = added
        self.table = table
        self.size = table.size
    }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        try EditOverlayStorage.read(at: offset, length: length,
                                    table: table, base: base, added: added)
    }
}
