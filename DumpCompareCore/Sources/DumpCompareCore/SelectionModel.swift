import Foundation

/// The current selection in a file, as an absolute half-open range
/// `[start, end)` always clamped to the file size (§10.2).
///
/// An empty selection (`start == end`) is a caret position. Construction
/// normalizes direction (start ≤ end) and clamps both edges to `fileSize`, so a
/// selection can never point outside the file, even after the file shrank.
public struct SelectionModel: Equatable, Sendable {
    public let start: UInt64
    public let end: UInt64
    public let fileSize: UInt64

    public var isEmpty: Bool { start == end }
    public var count: UInt64 { end - start }
    public var blockRange: BlockRange? {
        BlockRange(start: start, end: end, fileSize: fileSize)
    }

    public init(start: UInt64, end: UInt64, fileSize: UInt64) {
        let s = min(start, end)
        let e = max(start, end)
        self.start = min(s, fileSize)
        self.end = min(e, fileSize)
        self.fileSize = fileSize
    }

    public init(start: UInt64, length: UInt64, fileSize: UInt64) {
        let s = min(start, fileSize)
        self.start = s
        self.end = s + min(length, fileSize - s) // cannot overflow: min ≤ fileSize - s
        self.fileSize = fileSize
    }

    public static func empty(at offset: UInt64, fileSize: UInt64) -> SelectionModel {
        SelectionModel(start: offset, end: offset, fileSize: fileSize)
    }

    /// Re-clamps this selection to a new file size (used after size-changing
    /// edits so the selection never points past EOF).
    public func clamped(to newSize: UInt64) -> SelectionModel {
        SelectionModel(start: start, end: end, fileSize: newSize)
    }
}
