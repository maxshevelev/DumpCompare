import Foundation

/// The wrapper an update file arrives in (§1.1).
///
/// A capsule is not part of the image — it is the envelope the vendor shipped
/// it in, and the image inside starts where `HeaderSize` says. Recognising one
/// is what turns "this file makes no sense" into "this file is an update".
enum Capsule {
    struct Layout {
        var name: String
        /// Where the total size is written, which is not the same field in
        /// every vendor's version of this header.
        var sizeOffset: UInt64
        /// Aptio signed capsules put a certificate between the header and the
        /// image, and only `RomImageOffset` knows how much of it there is.
        var romImageOffsetAt: UInt64?
    }

    static let headerSizeOffset: UInt64 = 0x10
    static let minimumHeaderSize: UInt64 = 0x1C

    static func layout(for guid: EFIGUID) -> Layout? { layouts[guid] }

    private static let layouts: [EFIGUID: Layout] = [
        KnownGUIDs.guid("3B6686BD-0D76-4030-B70E-B5519E2FC5A0"):
            Layout(name: "EFI capsule", sizeOffset: 0x18, romImageOffsetAt: nil),
        KnownGUIDs.guid("6DCBD5ED-E82D-4C44-BDA1-7194199AD92A"):
            Layout(name: "FMP capsule", sizeOffset: 0x18, romImageOffsetAt: nil),
        KnownGUIDs.guid("539182B9-ABB5-4391-B69A-E3A943F72FCC"):
            Layout(name: "Intel capsule", sizeOffset: 0x18, romImageOffsetAt: nil),
        KnownGUIDs.guid("E20BAFD3-9914-4F4F-9537-3129E090EB3C"):
            Layout(name: "Lenovo capsule", sizeOffset: 0x18, romImageOffsetAt: nil),
        KnownGUIDs.guid("25B5FE76-8243-4A5C-A9BD-7EE3246198B5"):
            Layout(name: "Lenovo capsule", sizeOffset: 0x18, romImageOffsetAt: nil),
        // Toshiba writes the full size where everyone else writes the flags.
        KnownGUIDs.guid("3BE07062-1D51-45D2-832B-F093257ED461"):
            Layout(name: "Toshiba capsule", sizeOffset: 0x14, romImageOffsetAt: nil),
        KnownGUIDs.guid("4A3CA68B-7723-48FB-803D-578CC1FEC44D"):
            Layout(name: "AMI Aptio signed capsule", sizeOffset: 0x18, romImageOffsetAt: 0x1C),
        KnownGUIDs.guid("14EEBB90-890A-43DB-AED1-5D3C4588A418"):
            Layout(name: "AMI Aptio unsigned capsule", sizeOffset: 0x18, romImageOffsetAt: nil)
    ]
}

extension Parser {
    /// Nil when there is no capsule here, which is the usual answer — a dump
    /// off a chip has no envelope.
    func parseCapsule(at offset: UInt64, limit: UInt64, depth: Int) -> UEFINode? {
        guard let guid = reader.guid(at: offset),
              let layout = Capsule.layout(for: guid),
              let headerSize = reader.uint32(at: offset + Capsule.headerSizeOffset),
              let imageSize = reader.uint32(at: offset + layout.sizeOffset)
        else { return nil }

        var bodyStart = offset + UInt64(headerSize)
        if let romImageOffsetAt = layout.romImageOffsetAt,
           let romImageOffset = reader.uint16(at: offset + romImageOffsetAt),
           UInt64(romImageOffset) >= Capsule.minimumHeaderSize {
            bodyStart = offset + UInt64(romImageOffset)
        }
        guard UInt64(headerSize) >= Capsule.minimumHeaderSize, bodyStart < limit else {
            note(.truncated(.capsuleHeader), at: offset + Capsule.headerSizeOffset)
            return nil
        }

        // A capsule that claims less than the file holds has something after
        // it, and that something is kept rather than quietly folded in (§1.1).
        var end = limit
        if UInt64(imageSize) > 0, offset + UInt64(imageSize) < limit {
            end = offset + UInt64(imageSize)
        }

        return UEFINode(
            kind: .capsule,
            name: layout.name,
            guid: guid,
            header: offset..<bodyStart,
            body: bodyStart..<end,
            children: parseTopLevel(bodyStart..<end, depth: depth + 1)
        )
    }
}
