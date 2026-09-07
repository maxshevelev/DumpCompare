import Foundation
import ToolModuleKit
import UEFIImage

/// The host's snapshot of the open file, seen as bytes a parser can read.
///
/// The two sides were written not to know about each other — `UEFIImage`
/// depends on nothing, and `ToolModuleKit` is the seam — so the ten lines that
/// introduce them live here, in a package of their own that both tool-modules
/// reading firmware can link.
public struct ToolContentByteSource: ByteSource {
    public let reader: any ToolContentReader

    public init(reader: any ToolContentReader) {
        self.reader = reader
    }

    public var byteCount: UInt64 { reader.size }

    public func bytes(in range: Range<UInt64>) -> [UInt8] {
        // The caller has already checked the range against `byteCount`, so a
        // failure here means the file moved under a snapshot that promised it
        // would not. Zeros of the right length keep the parser's own bounds
        // arithmetic true; a short array would not.
        (try? reader.read(range)) ?? [UInt8](repeating: 0, count: Int(range.count))
    }
}
