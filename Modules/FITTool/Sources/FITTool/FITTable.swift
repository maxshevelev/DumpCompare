import Foundation
import UEFIFormat

/// The table as it was found: where it is, what is in it, and what its rows
/// actually point at (§2, §3).
public struct FITTable: Equatable, Sendable {
    /// The table itself, header row included.
    public var range: Range<UInt64>
    /// Where the pointer that led here lives, and what it held.
    public var pointerOffset: UInt64
    public var pointerAddress: UInt64
    public var rows: [FITRow]
    /// The header's checksum byte, and what it should be for the table as it
    /// stands (§5).
    public var storedChecksum: UInt8
    public var computedChecksum: UInt8
    /// The header's `ChecksumValid` bit: when it is clear, the checksum means
    /// nothing and nobody checks it.
    public var checksumIsChecked: Bool

    public var header: FITEntry? { rows.first?.entry }
    /// Every row but the header — what a reader of the table is actually
    /// interested in.
    public var entries: [FITRow] { Array(rows.dropFirst()) }

    public var checksumIsCorrect: Bool { storedChecksum == computedChecksum }
}

/// A row and what it leads to.
public struct FITRow: Equatable, Sendable {
    public var entry: FITEntry
    public var target: FITTarget

    /// The size worth showing. For microcode the row's own field is required to
    /// be zero and the truth is in the component (§7.1) — showing the field raw
    /// is how a tool comes to display a silent `0` that is indistinguishable
    /// from "this type does not use the field" (§11).
    public var effectiveSize: UInt64? {
        if case .microcode(let header) = target { return UInt64(header.totalSize) }
        return entry.size == 0 ? nil : entry.sizeInBytes
    }
}

/// The first eight bytes of a policy row at version 0: a descriptor of
/// Index/IO registers rather than a pointer (§7.3).
///
/// ```
///   0x00   2   IndexRegisterAddress
///   0x02   2   DataRegisterAddress
///   0x04   1   AccessWidthInBytes   (1 or 2)
///   0x05   1   BitPosition
///   0x06   2   Index
/// ```
public struct FITIndexIODescriptor: Equatable, Sendable {
    public var indexRegister: UInt16
    public var dataRegister: UInt16
    public var accessWidth: UInt8
    public var bitPosition: UInt8
    public var index: UInt16
}

/// What is at a row's address.
public enum FITTarget: Equatable, Sendable {
    /// The row points nowhere by design: the header, an empty slot.
    case nothing
    /// A policy row whose first eight bytes are an Index/IO register
    /// descriptor rather than a pointer (§7.3). Reading it as an address is
    /// exactly the mistake the format invites here.
    case indexIORegisters(FITIndexIODescriptor)
    /// The address does not land in this image.
    case outsideTheImage
    case microcode(MicrocodeHeader)
    /// `FF FF FF FF`: a slot reserved for a later update, which the
    /// specification allows a row to point at (§7.1).
    case emptyMicrocodeSlot(offset: UInt64)
    /// Bytes in the image, named by whatever the tree says covers them.
    case bytes(offset: UInt64, description: String?)

    /// Where it is in the file, when it is anywhere.
    public var offset: UInt64? {
        switch self {
        case .microcode(let header): return header.offset
        case .emptyMicrocodeSlot(let offset): return offset
        case .bytes(let offset, _): return offset
        case .nothing, .indexIORegisters, .outsideTheImage: return nil
        }
    }
}

/// What one look at an image found.
public struct FITReport: Equatable, Sendable {
    public var table: FITTable?
    public var problems: [FITProblem]
    /// Offsets carrying the `_FIT_   ` signature, collected when the pointer
    /// did not lead to a table. Both sides of the link are worth checking, and
    /// a table the pointer has lost is still a table the user can look at
    /// (§2.1).
    public var candidates: [UInt64]
    /// `address = offset + addressDiff`.
    public var addressDiff: UInt64
    /// No Volume Top File said so, so the image was taken to be mapped against
    /// the top of the address space. True for a full flash dump and false for
    /// a region cut out of one — which is why it is said out loud.
    public var addressDiffIsAssumed: Bool
}

public enum FITReader {
    /// Finds the table and reads it.
    ///
    /// The image is the parse from `UEFIFormat`, and it is used for exactly two
    /// things: the address mapping, which comes from the Volume Top File and
    /// therefore from a full parse, and naming what a row points at. Nil is
    /// allowed — the table can still be read, on the assumption every full
    /// flash dump satisfies.
    public static func read(_ reader: ImageReader, image: UEFIImage?) -> FITReport {
        let assumed = image?.addressDiff == nil
        let addressDiff = image?.addressDiff ?? (0x1_0000_0000 &- reader.count)
        // That the mapping was assumed is not a problem with the table: it is a
        // caveat about the reading, and it belongs in the line that says what
        // was read rather than in the list of what is wrong.
        var problems: [FITProblem] = []

        func report(_ table: FITTable?, _ candidates: [UInt64] = []) -> FITReport {
            FITReport(
                table: table,
                problems: problems,
                candidates: candidates,
                addressDiff: addressDiff,
                addressDiffIsAssumed: assumed
            )
        }

        guard reader.count > 0, addressDiff <= FIT.pointerAddress,
              let pointerOffset = offset(of: FIT.pointerAddress, diff: addressDiff, in: reader),
              let pointerAddress = reader.uint32(at: pointerOffset).map(UInt64.init)
        else {
            problems.append(FITProblem(.imageHasNoPointer))
            return report(nil, scanForSignatures(in: reader))
        }

        guard let tableOffset = offset(of: pointerAddress, diff: addressDiff, in: reader) else {
            problems.append(FITProblem(
                .pointerLeadsOutsideTheImage(address: pointerAddress), at: pointerOffset
            ))
            return report(nil, scanForSignatures(in: reader))
        }
        guard reader.uint64(at: tableOffset) == FIT.signature else {
            problems.append(FITProblem(
                .noTableAtThePointer(address: pointerAddress), at: tableOffset
            ))
            return report(nil, scanForSignatures(in: reader))
        }

        guard let header = FITEntry.read(at: tableOffset, index: 0, in: reader),
              header.size > 0
        else {
            problems.append(FITProblem(.tableHasNoEntries, at: tableOffset + 0x08))
            return report(nil)
        }

        // The header's `Size` counts entries, not bytes — the field everyone
        // reads wrong (§4).
        var count = UInt64(header.size)
        let end = tableOffset + count * FITEntry.size
        if end > reader.count {
            problems.append(FITProblem(
                .tableRunsPastTheEnd(entries: header.size), at: tableOffset + 0x08
            ))
            count = (reader.count - tableOffset) / FITEntry.size
        }

        let rows = (0..<Int(count)).compactMap { index -> FITRow? in
            let offset = tableOffset + UInt64(index) * FITEntry.size
            guard let entry = FITEntry.read(at: offset, index: index, in: reader) else { return nil }
            return FITRow(entry: entry, target: target(of: entry, diff: addressDiff, reader: reader, image: image))
        }
        let range = tableOffset..<(tableOffset + UInt64(rows.count) * FITEntry.size)

        let table = FITTable(
            range: range,
            pointerOffset: pointerOffset,
            pointerAddress: pointerAddress,
            rows: rows,
            storedChecksum: header.checksum,
            computedChecksum: checksum(of: range, in: reader),
            checksumIsChecked: header.checksumValid
        )
        problems += FITValidator.problems(in: table, reader: reader, addressDiff: addressDiff)
        return report(table)
    }

    /// The checksum the table should carry: every byte of it, with the
    /// header's own checksum field counted as zero, summing to zero (§5).
    public static func checksum(of range: Range<UInt64>, in reader: ImageReader) -> UInt8 {
        guard var sum = Checksums.sum8(of: range, in: reader),
              let stored = reader.uint8(at: range.lowerBound + 0x0F)
        else { return 0 }
        sum = sum &- stored
        return 0 &- sum
    }

    private static func offset(
        of address: UInt64, diff: UInt64, in reader: ImageReader
    ) -> UInt64? {
        guard address >= diff else { return nil }
        let offset = address - diff
        return offset + 4 <= reader.count ? offset : nil
    }

    /// What a row leads to, checked by reading it — one look at forty-eight
    /// bytes, and the whole class of "missed the address by a digit" is caught
    /// (§11).
    private static func target(
        of entry: FITEntry,
        diff: UInt64,
        reader: ImageReader,
        image: UEFIImage?
    ) -> FITTarget {
        if entry.isHeader || entry.isEmptySlot { return .nothing }
        if entry.type == FIT.tpmPolicyType || entry.type == FIT.txtPolicyType,
           entry.version == FIT.policyIndexIOVersion {
            // The first eight bytes are a descriptor of Index/IO registers, not
            // a pointer (§7.3) — and reading them as an address is exactly the
            // mistake the format invites here. They are the row's own `Address`
            // field, already read, so there is nothing left to fetch.
            let raw = entry.address
            return .indexIORegisters(FITIndexIODescriptor(
                indexRegister: UInt16(truncatingIfNeeded: raw),
                dataRegister: UInt16(truncatingIfNeeded: raw >> 16),
                accessWidth: UInt8(truncatingIfNeeded: raw >> 32),
                bitPosition: UInt8(truncatingIfNeeded: raw >> 40),
                index: UInt16(truncatingIfNeeded: raw >> 48)
            ))
        }
        guard entry.address >= diff else { return .outsideTheImage }
        let offset = entry.address - diff
        guard offset < reader.count else { return .outsideTheImage }

        if entry.type == FIT.microcodeType {
            if let header = MicrocodeHeader.read(at: offset, in: reader) {
                return .microcode(header)
            }
            if reader.uint32(at: offset) == 0xFFFF_FFFF {
                return .emptyMicrocodeSlot(offset: offset)
            }
        }
        return .bytes(offset: offset, description: image?.innermostNode(containing: offset)?.name)
    }

    /// Every `_FIT_   ` in the image. Only worth doing when the pointer has
    /// failed: a table the pointer agrees with makes every other candidate
    /// somebody else's bytes that happened to match (§2.1).
    static func scanForSignatures(in reader: ImageReader) -> [UInt64] {
        var found: [UInt64] = []
        let signature = FIT.signatureBytes
        var offset: UInt64 = 0
        let window: UInt64 = 1 << 20
        while offset + UInt64(signature.count) <= reader.count {
            let end = min(offset + window, reader.count)
            guard let bytes = reader.bytes(offset..<end) else { break }
            var index = 0
            while index + signature.count <= bytes.count {
                if bytes[index] == signature[0],
                   Array(bytes[index..<(index + signature.count)]) == signature {
                    found.append(offset + UInt64(index))
                }
                index += 1
            }
            if end == reader.count { break }
            offset = end - UInt64(signature.count - 1)
        }
        return found
    }
}
