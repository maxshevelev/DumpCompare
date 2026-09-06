import Foundation

/// `INTEL_MICROCODE_HEADER` (§7.1).
///
/// Microcode is what the FIT table mostly points at, so recognising it is not
/// a luxury here: a tool-module editing FIT needs to know whether the address
/// in an entry lands on a microcode image, on an empty slot, or on nothing at
/// all — which is the whole of §11 of `FIT_TABLE_FORMAT.md`.
enum Microcode {
    static let headerSize: UInt64 = 0x30
    /// `HeaderType`, and the dword the raw scan looks for.
    static let headerType: UInt32 = 1
    static let loaderRevision: UInt32 = 1
    static let maxSize: UInt32 = 0xFF_FFFF
    /// A `DataSize` of zero means 2000 bytes, which the specification wrote
    /// down once and never repeated.
    static let defaultDataSize: UInt32 = 2000

    /// Every check of `intelMicrocodeHeaderValid`, all of them required — the
    /// dword `0x00000001` is far too common for any subset to do.
    static func headerIsValid(
        headerType: UInt32,
        loaderRevision: UInt32,
        dataSize: UInt32,
        totalSize: UInt32,
        year: UInt16,
        month: UInt8,
        day: UInt8
    ) -> Bool {
        guard headerType == Microcode.headerType,
              loaderRevision == Microcode.loaderRevision,
              dataSize % 4 == 0,
              dataSize <= maxSize,
              totalSize >= dataSize,
              totalSize <= maxSize
        else { return false }
        return isValidBCDDay(day) && isValidBCDMonth(month) && isValidBCDYear(year)
    }

    /// The date is packed BCD, and it is the only field in this header with
    /// enough structure to reject a false positive on its own.
    static func isValidBCDDay(_ day: UInt8) -> Bool {
        switch day {
        case 0x01...0x09, 0x10...0x19, 0x20...0x29, 0x30...0x31: return true
        default: return false
        }
    }

    static func isValidBCDMonth(_ month: UInt8) -> Bool {
        switch month {
        case 0x01...0x09, 0x10...0x12: return true
        default: return false
        }
    }

    static func isValidBCDYear(_ year: UInt16) -> Bool {
        switch year {
        case 0x1990...0x1999, 0x2000...0x2009, 0x2010...0x2019,
             0x2020...0x2029, 0x2030...0x2039, 0x2040...0x2049:
            return true
        default:
            return false
        }
    }
}

/// A microcode header that checked out, read back as values.
///
/// Public because a FIT table's entries point at these, and the tool-module
/// that edits FIT has to show which processor and which revision an entry
/// leads to. Reading them there instead would be §7.1 written down twice.
public struct MicrocodeHeader: Equatable, Sendable {
    public var offset: UInt64
    public var updateRevision: UInt32
    /// The date, as the packed BCD it is stored in.
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var processorSignature: UInt32
    public var checksum: UInt32
    public var platformIDs: UInt32
    public var dataSize: UInt32
    public var totalSize: UInt32

    public static let size: UInt64 = 0x30

    /// Reads a header and puts it through every check of §7.1. Nil means these
    /// bytes are not microcode — which is the usual answer, since the dword
    /// this starts with is `0x00000001`.
    public static func read(at offset: UInt64, in reader: ImageReader) -> MicrocodeHeader? {
        guard let headerType = reader.uint32(at: offset),
              let updateRevision = reader.uint32(at: offset + 0x04),
              let year = reader.uint16(at: offset + 0x08),
              let day = reader.uint8(at: offset + 0x0A),
              let month = reader.uint8(at: offset + 0x0B),
              let processorSignature = reader.uint32(at: offset + 0x0C),
              let checksum = reader.uint32(at: offset + 0x10),
              let loaderRevision = reader.uint32(at: offset + 0x14),
              let platformIDs = reader.uint32(at: offset + 0x18),
              let dataSize = reader.uint32(at: offset + 0x1C),
              let totalSize = reader.uint32(at: offset + 0x20),
              totalSize != 0,
              Microcode.headerIsValid(
                  headerType: headerType,
                  loaderRevision: loaderRevision,
                  dataSize: dataSize,
                  totalSize: totalSize,
                  year: year, month: month, day: day
              )
        else { return nil }

        return MicrocodeHeader(
            offset: offset,
            updateRevision: updateRevision,
            year: year, month: month, day: day,
            processorSignature: processorSignature,
            checksum: checksum,
            platformIDs: platformIDs,
            dataSize: dataSize,
            totalSize: totalSize
        )
    }

    /// Header and data together, as `TotalSize` gives it.
    public var range: Range<UInt64> { offset..<(offset + UInt64(totalSize)) }

    /// `2019-07-15`, unpacked from the BCD. The fields are already known to be
    /// valid BCD, or this header would not exist.
    public var date: String {
        String(format: "%04X-%02X-%02X", year, month, day)
    }
}

extension Parser {
    /// One microcode image. Nil when the header does not check out, which
    /// leaves no diagnostic — `0x00000001` appears everywhere.
    func parseMicrocode(at offset: UInt64, limit: UInt64) -> UEFINode? {
        guard offset + Microcode.headerSize <= limit,
              let header = MicrocodeHeader.read(at: offset, in: reader)
        else { return nil }

        var end = header.range.upperBound
        if end > limit {
            note(.truncated(.microcodeHeader), at: offset + 0x20)
            end = limit
        }
        verifyMicrocodeChecksum(at: offset, end: end)

        return UEFINode(
            kind: .microcode,
            name: String(
                format: "Microcode %08X, revision %08X",
                header.processorSignature,
                header.updateRevision
            ),
            header: offset..<(offset + Microcode.headerSize),
            body: (offset + Microcode.headerSize)..<end,
            // Whatever FIT points at must not move (§11), and the FIT table
            // points at microcode. Deciding that here saves every tool-module
            // that reads this tree from having to.
            isFixed: true
        )
    }

    /// The whole image, dwords, sums to zero (§7.1).
    private func verifyMicrocodeChecksum(at offset: UInt64, end: UInt64) {
        guard (end - offset) % 4 == 0,
              let sum = Checksums.sum32(of: offset..<end, in: reader),
              sum != 0,
              let stored = reader.uint32(at: offset + 0x10)
        else { return }
        note(
            .checksumMismatch(
                .microcodeHeader,
                stored: UInt64(stored),
                computed: UInt64(stored &- sum)
            ),
            at: offset + 0x10
        )
    }
}
