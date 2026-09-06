import Foundation

/// An image as it *would* be, with some writes applied.
///
/// Nothing here writes to a file. But a change to an image invalidates the
/// checksums of whatever contains it, and a checksum is computed over the bytes
/// as they will be — not as they are. So a tool-module builds its writes, lays
/// them over the image it read, and asks `UEFIChecksums` what the result needs;
/// the answer joins the same transaction, and the whole repair lands as one
/// undoable step.
///
/// The writes are kept as they were given. They are few and small — a component
/// and a table — so a read walks them rather than building a copy of the image
/// with them in it.
public struct OverlayByteSource: ByteSource {
    public struct Patch: Sendable {
        public var offset: UInt64
        public var bytes: [UInt8]

        public init(offset: UInt64, bytes: [UInt8]) {
            self.offset = offset
            self.bytes = bytes
        }

        var range: Range<UInt64> { offset..<(offset + UInt64(bytes.count)) }
    }

    private let base: any ByteSource
    private let patches: [Patch]

    public init(base: any ByteSource, patches: [Patch]) {
        self.base = base
        // Later patches win, so they are applied in the order they were given.
        self.patches = patches
    }

    public var byteCount: UInt64 { base.byteCount }

    public func bytes(in range: Range<UInt64>) -> [UInt8] {
        var bytes = base.bytes(in: range)
        for patch in patches {
            // The bounds first and the range afterwards: `a..<b` with `a > b`
            // traps, and a patch that misses this read entirely gives exactly
            // that.
            let start = max(patch.range.lowerBound, range.lowerBound)
            let end = min(patch.range.upperBound, range.upperBound)
            guard start < end else { continue }
            let count = Int(end - start)
            let intoBytes = Int(start - range.lowerBound)
            let fromPatch = Int(start - patch.offset)
            bytes.replaceSubrange(
                intoBytes..<(intoBytes + count),
                with: patch.bytes[fromPatch..<(fromPatch + count)]
            )
        }
        return bytes
    }
}
