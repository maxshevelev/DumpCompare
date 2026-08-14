import Foundation

/// A validated half-open byte range `[start, end)` used by selection and
/// navigation dialogs.
///
/// Construction is failable: a range whose start is past the file size, whose
/// end precedes its start, or whose end exceeds the file size is rejected.
/// A length-based range is clamped to the file size instead of rejected when it
/// simply overshoots EOF, matching how a hex editor treats "jump to offset X".
public struct BlockRange: Equatable, Sendable {
    public let start: UInt64
    /// Exclusive end (half-open: `[start, end)`).
    public let end: UInt64
    /// The file size the range was validated against.
    public let fileSize: UInt64

    public var count: UInt64 { end - start }
    public var isEmpty: Bool { start == end }

    public init?(start: UInt64, end: UInt64, fileSize: UInt64) {
        guard start <= end, end <= fileSize else { return nil }
        self.start = start
        self.end = end
        self.fileSize = fileSize
    }

    public init?(start: UInt64, length: UInt64, fileSize: UInt64) {
        guard start <= fileSize else { return nil }
        self.start = start
        // Clamp an overshooting length to EOF rather than rejecting it.
        self.end = start + min(length, fileSize - start)
        self.fileSize = fileSize
    }
}
