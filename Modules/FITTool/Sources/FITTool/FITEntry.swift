import Foundation
import UEFIImage

/// One sixteen-byte row of the table — the header included, since it is a row
/// like any other (`Design/UEFI/FIT_TABLE_FORMAT.md` §3).
///
/// ```
///   0x00   8   Address    (LE)
///   0x08   3   Size       (LE, 24-bit, in 16-byte units)
///   0x0B   1   Reserved
///   0x0C   2   Version    (LE, BCD)
///   0x0E   1   Type[6:0] | ChecksumValid[7]
///   0x0F   1   Checksum
/// ```
public struct FITEntry: Equatable, Sendable {
    /// Its place in the table; 0 is the header.
    public var index: Int
    /// Where the row itself is in the file — what a write to it addresses.
    public var offset: UInt64
    public var address: UInt64
    /// As stored. Most types do not use it, and for microcode it is required to
    /// be zero — the real size lives in the component (§7.1), which is why
    /// showing this raw is how a tool ends up displaying a silent `0` (§11).
    public var size: UInt32
    /// Must be zero, except on a CSE SecureBoot entry where it is the subtype
    /// (§7.5).
    public var reserved: UInt8
    /// BCD: high byte major, low byte minor.
    public var version: UInt16
    /// Seven bits. The eighth is `checksumValid`.
    public var type: UInt8
    public var checksumValid: Bool
    public var checksum: UInt8

    public static let size: UInt64 = 16

    public init(
        index: Int,
        offset: UInt64,
        address: UInt64,
        size: UInt32,
        reserved: UInt8,
        version: UInt16,
        type: UInt8,
        checksumValid: Bool,
        checksum: UInt8
    ) {
        self.index = index
        self.offset = offset
        self.address = address
        self.size = size
        self.reserved = reserved
        self.version = version
        self.type = type
        self.checksumValid = checksumValid
        self.checksum = checksum
    }

    /// Reads a row. Nil only when the bytes are not there — every field of a
    /// row is valid as a value, and what is wrong with it is a diagnostic
    /// rather than a refusal to read.
    public static func read(at offset: UInt64, index: Int, in reader: ImageReader) -> FITEntry? {
        guard let address = reader.uint64(at: offset),
              let size = reader.uint24(at: offset + 0x08),
              let reserved = reader.uint8(at: offset + 0x0B),
              let version = reader.uint16(at: offset + 0x0C),
              let typeByte = reader.uint8(at: offset + 0x0E),
              let checksum = reader.uint8(at: offset + 0x0F)
        else { return nil }

        return FITEntry(
            index: index,
            offset: offset,
            address: address,
            size: size,
            reserved: reserved,
            version: version,
            type: typeByte & 0x7F,
            checksumValid: typeByte & 0x80 != 0,
            checksum: checksum
        )
    }

    /// `1.00`, unpacked from the BCD the field holds.
    public var versionText: String {
        String(format: "%X.%02X", version >> 8, version & 0xFF)
    }

    public var isHeader: Bool { type == FIT.headerType }
    /// A slot a vendor reserved for a later update. Legal, and the safest place
    /// to add an entry (§9.4).
    public var isEmptySlot: Bool { type == FIT.emptyType }

    /// What `Size` means in bytes, for the types that use it at all.
    public var sizeInBytes: UInt64 { UInt64(size) * 16 }
}

/// The table's constants (§13) and the names for what is in it (§6).
public enum FIT {
    /// `_FIT_   ` read as a little-endian 64-bit number — it lives in the
    /// header row's `Address` field, where every other row keeps a pointer.
    public static let signature: UInt64 = 0x2020_205F_5449_465F
    /// The same eight bytes, derived rather than typed a second time — the
    /// first spelling of them here was `_TIF_`, and it cost a test to notice.
    public static let signatureBytes: [UInt8] =
        (0..<8).map { UInt8(truncatingIfNeeded: signature >> (8 * $0)) }
    /// The pointer's physical address: `0x40` from the top of the address
    /// space (§2).
    public static let pointerAddress: UInt64 = 0xFFFF_FFC0

    public static let headerType: UInt8 = 0x00
    public static let microcodeType: UInt8 = 0x01
    public static let startupACMType: UInt8 = 0x02
    public static let tpmPolicyType: UInt8 = 0x08
    public static let txtPolicyType: UInt8 = 0x0A
    public static let cseSecureBootType: UInt8 = 0x10
    public static let emptyType: UInt8 = 0x7F

    /// A policy entry whose version is 0 keeps an Index/IO register descriptor
    /// in the first eight bytes, not an address (§7.3).
    public static let policyIndexIOVersion: UInt16 = 0

    public static func typeName(_ type: UInt8) -> String {
        switch type {
        case headerType: return "FIT Header"
        case microcodeType: return "Microcode"
        case startupACMType: return "Startup ACM"
        case 0x03: return "Diagnostic ACM"
        case 0x04: return "Platform Boot Policy"
        case 0x06: return "FIT Reset State"
        case 0x07: return "BIOS Startup Module"
        case tpmPolicyType: return "TPM Policy"
        case 0x09: return "BIOS Policy"
        case txtPolicyType: return "TXT Policy"
        case 0x0B: return "Boot Guard Key Manifest"
        case 0x0C: return "Boot Guard Boot Policy"
        case cseSecureBootType: return "CSE SecureBoot Settings"
        case 0x1A: return "VAB Provisioning Table"
        case 0x1B: return "VAB Key Manifest"
        case 0x1C: return "VAB Image Manifest"
        case 0x1D: return "VAB Image Hash Descriptors"
        case 0x2C: return "SACM Debug Record"
        case 0x2D: return "ACM Feature Policy"
        case 0x2E: return "SCRTM Error Record"
        case 0x2F: return "JMP Debug Policy"
        case emptyType: return "Empty slot"
        case 0x30...0x70: return String(format: "OEM reserved 0x%02X", type)
        default: return String(format: "Reserved 0x%02X", type)
        }
    }

    /// The subtype a CSE SecureBoot entry keeps in its `Reserved` byte (§7.5).
    public static func cseSecureBootSubtypeName(_ subtype: UInt8) -> String {
        switch subtype {
        case 1: return "Key Hash"
        case 2: return "CSE Measurement Hash"
        case 3: return "Boot Policy"
        case 4: return "Other Boot Policy"
        case 5: return "OEM SMIP"
        case 6: return "MRC Training Data"
        case 7: return "IBBL Hash"
        case 8: return "IBB Hash"
        case 9: return "OEM ID"
        case 10: return "OEM SKU ID"
        case 11: return "Boot Device Indicator"
        case 12: return "FIT Patch Manifest"
        case 13: return "AC Module Manifest"
        default: return String(format: "Subtype %d", subtype)
        }
    }
}
