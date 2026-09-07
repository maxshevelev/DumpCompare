import Foundation
@testable import FITTool
import UEFIImage

/// Images with a FIT in them, built byte by byte.
///
/// The tables worth testing against are the broken ones — an address off by a
/// digit, a checksum left over from the edit before, types out of order — and
/// those have to be built rather than found. Every way of breaking one is a
/// parameter here, and no real dump goes into this repository.
/// Bytes, little-endian, in the order they are written down.
struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    var count: UInt64 { UInt64(bytes.count) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes += (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func u24(_ value: UInt32) {
        bytes += (0..<3).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func u32(_ value: UInt32) {
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func u64(_ value: UInt64) {
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    mutating func guid(_ value: EFIGUID) { bytes += value.bytes }

    mutating func raw(_ value: [UInt8]) { bytes += value }

    mutating func fill(_ count: UInt64, with byte: UInt8) {
        bytes += [UInt8](repeating: byte, count: Int(count))
    }

    mutating func pad(to size: UInt64, with byte: UInt8) {
        if count < size { fill(size - count, with: byte) }
    }
}

enum TestFIT {
    /// A row of the table, said in terms of what it is meant to point at.
    struct Row {
        var type: UInt8
        /// An offset in the image; turned into an address by the builder.
        var target: UInt64?
        /// Or an address written literally, for the rows that are wrong.
        var address: UInt64?
        var size: UInt32 = 0
        var reserved: UInt8 = 0
        var version: UInt16 = 0x0100
        var checksumValid: Bool = false
        var checksum: UInt8 = 0

        init(
            _ type: UInt8,
            target: UInt64? = nil,
            address: UInt64? = nil,
            size: UInt32 = 0,
            reserved: UInt8 = 0,
            version: UInt16 = 0x0100
        ) {
            self.type = type
            self.target = target
            self.address = address
            self.size = size
            self.reserved = reserved
            self.version = version
        }
    }

    /// An image the size of a small flash chip, erased, with a table in it.
    static func image(
        size: UInt64 = 0x1_0000,
        tableOffset: UInt64 = 0x1000,
        rows: [Row],
        pointerAddress: UInt64? = nil,
        entryCount: UInt32? = nil,
        checksum: UInt8? = nil,
        checksumValid: Bool = true,
        headerType: UInt8 = FIT.headerType,
        addressDiff: UInt64? = nil,
        contents: [UInt64: [UInt8]] = [:]
    ) -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: Int(size))
        let diff = addressDiff ?? self.addressDiff(of: size)
        for (offset, bytes) in contents {
            image.replaceSubrange(Int(offset)..<(Int(offset) + bytes.count), with: bytes)
        }

        var table: [UInt8] = []
        table += entryBytes(
            address: FIT.signature,
            size: entryCount ?? UInt32(rows.count + 1),
            reserved: 0,
            version: 0x0100,
            type: headerType,
            checksumValid: checksumValid,
            checksum: 0
        )
        for row in rows {
            table += entryBytes(
                address: row.address ?? row.target.map { $0 + diff } ?? 0,
                size: row.size,
                reserved: row.reserved,
                version: row.version,
                type: row.type,
                checksumValid: row.checksumValid,
                checksum: row.checksum
            )
        }
        // The header's checksum is what makes every byte of the table sum to
        // zero (§5).
        table[0x0F] = checksum ?? (0 &- Checksums.sum8(table))
        image.replaceSubrange(Int(tableOffset)..<(Int(tableOffset) + table.count), with: table)

        let pointer = pointerAddress ?? (tableOffset + diff)
        let pointerOffset = Int(FIT.pointerAddress - diff)
        for index in 0..<4 {
            image[pointerOffset + index] = UInt8(truncatingIfNeeded: pointer >> (8 * index))
        }
        return image
    }

    /// What the reader assumes when no volume top file says otherwise.
    static func addressDiff(of size: UInt64) -> UInt64 { 0x1_0000_0000 - size }

    private static func entryBytes(
        address: UInt64,
        size: UInt32,
        reserved: UInt8,
        version: UInt16,
        type: UInt8,
        checksumValid: Bool,
        checksum: UInt8
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: address >> (8 * $0)) }
        bytes += (0..<3).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }
        bytes.append(reserved)
        bytes += (0..<2).map { UInt8(truncatingIfNeeded: version >> (8 * $0)) }
        bytes.append(type & 0x7F | (checksumValid ? 0x80 : 0))
        bytes.append(checksum)
        return bytes
    }

    /// An Intel microcode image, its dword checksum correct.
    static func microcode(
        signature: UInt32 = 0x0008_06EA,
        revision: UInt32 = 0xF0,
        totalSize: UInt32 = 0x100,
        platformIDs: UInt32 = 1
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        func u32(_ value: UInt32) {
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        u32(1)                     // HeaderType
        u32(revision)
        bytes += [0x19, 0x20]      // DateYear, BCD little-endian
        bytes += [0x15, 0x07]      // DateDay, DateMonth, BCD
        u32(signature)
        u32(0)                     // Checksum, filled in below
        u32(1)                     // LoaderRevision
        u32(platformIDs)
        u32(0x40)                  // DataSize
        u32(totalSize)
        u32(0)                     // MetadataSize
        u32(0)                     // UpdateRevisionMin
        u32(0)                     // Reserved
        bytes += [UInt8](repeating: 0x5A, count: Int(totalSize) - bytes.count)

        let sum = Checksums.sum32(of: 0..<UInt64(bytes.count), in: ImageReader(bytes)) ?? 0
        let stored = 0 &- sum
        for index in 0..<4 { bytes[0x10 + index] = UInt8(truncatingIfNeeded: stored >> (8 * index)) }
        return bytes
    }
}
