import Foundation
import CoreGraphics

/// Pure geometry for the hex-dump grid (§6 of REQUIREMENTS.md).
///
/// A row holds 16 bytes split into two groups of 8 (`8 bytes + space + 8
/// bytes`). Within a group the bytes are packed into words of `wordSize` bytes
/// (1, 2, 4, or 8): the word's bytes are drawn adjacent, and words are separated
/// by a space. A word of one byte is today's byte-per-cell dump. The row also
/// has a hexadecimal offset column on the left and an ASCII column on the right.
/// All metrics are passed in (monospaced character width, row height, word size)
/// so the layout has no AppKit dependency and is unit-testable. The full row
/// width — `contentWidth` — is a computed quantity that depends on the word size.
///
/// All y-coordinates are in a flipped coordinate space: row 0 is at y=0 and
/// rows grow downward, matching how the hex view is drawn.
struct HexLayout: Equatable {
    static let bytesPerRow = 16
    static let groupSize = 8

    /// Width of one monospaced character.
    let charWidth: CGFloat
    /// Height of one row.
    let rowHeight: CGFloat
    /// Leading whitespace before the offset column.
    let leftPadding: CGFloat
    /// Trailing whitespace after the ASCII column.
    let rightPadding: CGFloat
    /// Number of bytes per word (1, 2, 4, or 8). Dump width depends on it.
    let wordSize: Int

    /// Width of the two-digit hex cell of one byte.
    let hexByteWidth: CGFloat
    /// Gap between adjacent words within a group (one character).
    let hexByteGap: CGFloat
    /// Width of one word: its bytes are packed with no gap between them.
    var wordWidth: CGFloat { CGFloat(wordSize) * hexByteWidth }
    /// Number of words in one 8-byte group.
    var wordsPerGroup: Int { Self.groupSize / wordSize }
    /// Width of one 8-byte group including word gaps.
    let groupWidth: CGFloat
    /// Gap between the two 8-byte groups (two characters).
    let betweenGroupsGap: CGFloat
    /// Number of hex digits shown in the offset column (≥ 8).
    let offsetColumnChars: Int
    /// Width of the offset column.
    let offsetColumnWidth: CGFloat
    /// Width of the 16-character ASCII column.
    let asciiColumnWidth: CGFloat
    /// Gap after the offset column (two characters).
    let gapAfterOffset: CGFloat
    /// Gap before the ASCII column (two characters).
    let gapBeforeAscii: CGFloat
    /// Full width of one row.
    let contentWidth: CGFloat

    init(
        charWidth: CGFloat,
        rowHeight: CGFloat,
        leftPadding: CGFloat = 12,
        rightPadding: CGFloat = 12,
        offsetColumnChars: Int = 8,
        wordSize: Int = 1
    ) {
        self.charWidth = charWidth
        self.rowHeight = rowHeight
        self.leftPadding = leftPadding
        self.rightPadding = rightPadding
        self.offsetColumnChars = max(8, offsetColumnChars)
        // Words are 1, 2, 4, or 8 bytes; anything else falls back to one byte.
        self.wordSize = (wordSize == 2 || wordSize == 4 || wordSize == 8) ? wordSize : 1

        hexByteWidth = 2 * charWidth
        hexByteGap = charWidth
        let wordsPerGroup = Self.groupSize / self.wordSize
        let wordWidth = CGFloat(self.wordSize) * hexByteWidth
        groupWidth = CGFloat(wordsPerGroup) * wordWidth + CGFloat(wordsPerGroup - 1) * hexByteGap
        betweenGroupsGap = 2 * charWidth
        offsetColumnWidth = CGFloat(self.offsetColumnChars) * charWidth
        asciiColumnWidth = CGFloat(Self.bytesPerRow) * charWidth
        gapAfterOffset = 2 * charWidth
        gapBeforeAscii = 2 * charWidth

        let hexColumnsWidth = 2 * groupWidth + betweenGroupsGap
        contentWidth = leftPadding
            + offsetColumnWidth + gapAfterOffset
            + hexColumnsWidth
            + gapBeforeAscii + asciiColumnWidth
            + rightPadding
    }

    // MARK: - Rows

    /// Number of rows needed to display `fileSize` bytes. An empty file still
    /// shows one row (all placeholder cells); when the length is a multiple of
    /// 16 an extra trailing placeholder row keeps the caret-at-EOF position on
    /// the grid.
    func rowCount(fileSize: UInt64) -> UInt64 {
        let dataRows = (fileSize + UInt64(Self.bytesPerRow - 1)) / UInt64(Self.bytesPerRow)
        let caretRow: UInt64 = (fileSize % UInt64(Self.bytesPerRow) == 0) ? 1 : 0
        return dataRows + caretRow
    }

    /// Absolute byte offset for `row`'s `column` (0..16). May exceed the file
    /// size — the caller decides whether that is a placeholder cell.
    func byteOffset(row: Int, column: Int) -> UInt64 {
        UInt64(row) * UInt64(Self.bytesPerRow) + UInt64(column)
    }

    /// Row/column for an absolute offset (column may be the byte after the last
    /// full row's last byte when the file length is not a multiple of 16).
    func rowColumn(of offset: UInt64) -> (row: Int, column: Int) {
        (row: Int(offset / UInt64(Self.bytesPerRow)), column: Int(offset % UInt64(Self.bytesPerRow)))
    }

    // MARK: - Frames

    /// Row indices intersecting `bounds` (bottom-exclusive), for virtualized
    /// drawing. Empty when `bounds` has no height.
    func visibleRowRange(in bounds: CGRect) -> Range<Int> {
        guard bounds.height > 0, rowHeight > 0 else { return 0..<0 }
        let first = max(0, Int(floor(bounds.minY / rowHeight)))
        let lastExclusive = max(0, Int(ceil(bounds.maxY / rowHeight)))
        return first..<lastExclusive
    }

    /// The frame of one row (full content width).
    func rowFrame(row: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(row) * rowHeight, width: contentWidth, height: rowHeight)
    }

    /// Total content height for a file of `fileSize` bytes.
    func totalHeight(fileSize: UInt64) -> CGFloat {
        CGFloat(rowCount(fileSize: fileSize)) * rowHeight
    }

    /// x-origin of byte `column`'s hex cell within the row. Bytes inside a word
    /// are packed together; words are separated by `hexByteGap`, and the two
    /// 8-byte groups by `betweenGroupsGap`.
    func hexByteX(column: Int) -> CGFloat {
        let group = column / Self.groupSize
        let inGroup = column % Self.groupSize
        let word = inGroup / wordSize
        let inWord = inGroup % wordSize
        let hexX = CGFloat(group) * (groupWidth + betweenGroupsGap)
            + CGFloat(word) * (wordWidth + hexByteGap)
            + CGFloat(inWord) * hexByteWidth
        return leftPadding + offsetColumnWidth + gapAfterOffset + hexX
    }

    /// Frame of byte `column`'s two-digit hex cell.
    func hexByteFrame(row: Int, column: Int) -> CGRect {
        CGRect(x: hexByteX(column: column), y: CGFloat(row) * rowHeight,
               width: hexByteWidth, height: rowHeight)
    }

    /// Frame of the offset column.
    func offsetColumnFrame(row: Int) -> CGRect {
        CGRect(x: leftPadding, y: CGFloat(row) * rowHeight,
               width: offsetColumnWidth, height: rowHeight)
    }

    /// x-origin of the ASCII character for byte `column`.
    func asciiX(column: Int) -> CGFloat {
        let hexEnd = leftPadding + offsetColumnWidth + gapAfterOffset
            + 2 * groupWidth + betweenGroupsGap + gapBeforeAscii
        return hexEnd + CGFloat(column) * charWidth
    }

    /// Frame of the ASCII column.
    func asciiColumnFrame(row: Int) -> CGRect {
        CGRect(x: asciiX(column: 0), y: CGFloat(row) * rowHeight,
               width: asciiColumnWidth, height: rowHeight)
    }

    /// Caret x-position within a byte cell. Nibble 0 places the caret before
    /// the high nibble, nibble 1 before the low nibble.
    func caretX(row: Int, column: Int, nibble: Int) -> CGFloat {
        hexByteFrame(row: row, column: column).minX + CGFloat(nibble) * charWidth
    }

    // MARK: - Hit testing

    enum ColumnKind: Equatable {
        case offset
        case hex(Int)
        case ascii(Int)
    }

    struct Hit: Equatable {
        let row: Int
        let column: ColumnKind
    }

    /// Converts a point in view coordinates to a row/column, or nil when the
    /// point is outside any row (or beyond the last row).
    func hitTest(point: CGPoint, rowCount: UInt64) -> Hit? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let row = Int(floor(point.y / rowHeight))
        guard row >= 0, UInt64(row) < rowCount else { return nil }

        // Every point in the hex region maps to a byte. A click between two
        // words — or in the gap between the two 8-byte groups — places the caret
        // on the following word (§6), so a click never falls dead between cells.
        let hexStart = leftPadding + offsetColumnWidth + gapAfterOffset
        let hexEnd = asciiX(column: 0)
        if point.x >= hexStart, point.x < hexEnd {
            for group in 0..<2 {
                let groupStart = hexStart + CGFloat(group) * (groupWidth + betweenGroupsGap)
                for word in 0..<wordsPerGroup {
                    let wordStart = groupStart + CGFloat(word) * (wordWidth + hexByteGap)
                    if point.x < wordStart + wordWidth {
                        // Inside the word, or in the gap just before it (the
                        // following word). A point past the last word clamps to
                        // the row's last byte below.
                        let inWord = point.x >= wordStart
                            ? min(wordSize - 1, Int((point.x - wordStart) / hexByteWidth))
                            : 0
                        return Hit(row: row, column: .hex(group * Self.groupSize + word * wordSize + inWord))
                    }
                }
            }
            return Hit(row: row, column: .hex(Self.bytesPerRow - 1))
        }

        let asciiStart = asciiX(column: 0)
        if point.x >= asciiStart, point.x < asciiStart + asciiColumnWidth {
            let col = min(Self.bytesPerRow - 1, Int((point.x - asciiStart) / charWidth))
            return Hit(row: row, column: .ascii(col))
        }

        if point.x >= leftPadding, point.x < hexStart {
            return Hit(row: row, column: .offset)
        }
        return nil
    }
}
