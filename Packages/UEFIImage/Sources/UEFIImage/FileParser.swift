import Foundation

/// `EFI_FFS_FILE_HEADER` and its variants (§5).
enum FFS {
    static let headerSize: UInt64 = 0x18
    /// FFSv3 large file.
    static let largeHeaderSize: UInt64 = 0x20
    /// Lenovo's large file in an FFSv2 Revision 2 volume — not in any
    /// specification, and in plenty of laptops.
    static let lenovoHeaderSize: UInt64 = 0x1C

    /// The same bit means different things depending on the *volume's*
    /// revision, not the file's (§5.3), which is the trap in this structure.
    static let tailPresent: UInt8 = 0x01   // volume revision 1
    static let largeFile: UInt8 = 0x01     // FFSv3, and Lenovo in FFSv2 rev 2
    static let fixed: UInt8 = 0x04
    static let checksumBit: UInt8 = 0x40

    /// What the body checksum field holds when the file does not have one.
    static let fixedChecksum: UInt8 = 0x5A    // volume revision 1
    static let fixedChecksum2: UInt8 = 0xAA   // revision 2

    static let padType: UInt8 = 0xF0
    static let rawType: UInt8 = 0x01
    /// In the file's *state* byte, not its attributes (§5.5).
    static let erasePolarity: UInt8 = 0x80

    /// Every file's body is a run of sections except these two, which are the
    /// bytes they say they are (§6).
    static func hasSections(_ type: UInt8) -> Bool {
        type != rawType && type != padType
    }
}

extension Parser {
    struct ParsedFile {
        var node: UEFINode
        /// Header through tail, before the walk aligns to the next file.
        var size: UInt64
    }

    /// One FFS file. Nil means the volume's body cannot be walked past this
    /// point — a size of zero or a header that does not fit — and the caller
    /// stops rather than looping on the same offset (§11).
    func parseFile(
        at offset: UInt64,
        limit: UInt64,
        ffsVersion: Int,
        volumeRevision: UInt8,
        depth: Int
    ) -> ParsedFile? {
        guard let name = reader.guid(at: offset),
              let headerChecksum = reader.uint8(at: offset + 0x10),
              let bodyChecksum = reader.uint8(at: offset + 0x11),
              let type = reader.uint8(at: offset + 0x12),
              let attributes = reader.uint8(at: offset + 0x13),
              let shortSize = reader.uint24(at: offset + 0x14),
              let state = reader.uint8(at: offset + 0x17)
        else {
            note(.truncated(.fileHeader), at: offset)
            return nil
        }

        let (headerSize, size) = fileSize(
            at: offset,
            shortSize: shortSize,
            attributes: attributes,
            ffsVersion: ffsVersion,
            volumeRevision: volumeRevision
        )
        guard let size else {
            note(.truncated(.fileHeader), at: offset + 0x18)
            return nil
        }
        guard size != 0 else {
            note(.zeroSize(.fileHeader), at: offset + 0x14)
            return nil
        }
        guard size >= headerSize else {
            note(.sizeMismatch(.fileHeader, stored: size, computed: headerSize), at: offset + 0x14)
            return nil
        }

        var end = offset + size
        if end > limit {
            note(.truncated(.fileBody), at: offset + 0x14)
            end = limit
            guard end - offset >= headerSize else { return nil }
        }

        // FFSv1 keeps two bytes of tail after the body, and nothing else does.
        let tailSize: UInt64 =
            volumeRevision == 1 && attributes & FFS.tailPresent != 0 && end - offset > headerSize
            ? 2 : 0
        let body = (offset + headerSize)..<(end - tailSize)
        let tail = (end - tailSize)..<end

        verifyFileChecksums(
            at: offset,
            headerSize: headerSize,
            body: body,
            headerChecksum: headerChecksum,
            bodyChecksum: bodyChecksum,
            attributes: attributes,
            volumeRevision: volumeRevision
        )
        if type > 0x0F && type != FFS.padType {
            note(.unknownType(.fileHeader, type), at: offset + 0x12)
        }

        // A file's erase polarity is its own, taken from its state byte rather
        // than from the volume, so that a volume holding files written under
        // both polarities still reads (§5.5).
        let emptyByte: UInt8 = state & FFS.erasePolarity != 0 ? 0xFF : 0x00
        var children: [UEFINode] = []
        if FFS.hasSections(type), !body.isEmpty {
            children = walkSections(
                body, ffsVersion: ffsVersion, emptyByte: emptyByte, depth: depth + 1
            )
        }

        let node = UEFINode(
            kind: .file,
            subtype: type,
            name: KnownGUIDs.name(of: name) ?? userInterfaceName(in: children)
                ?? FFS.typeName(type),
            guid: name,
            header: offset..<(offset + headerSize),
            body: body,
            tail: tail,
            isFixed: attributes & FFS.fixed != 0,
            children: children
        )
        return ParsedFile(node: node, size: end - offset)
    }

    /// The name a person gave the file, if one of its sections carries one.
    /// Worth going looking for: it is the only readable name most files have,
    /// and without it a volume is three hundred rows of GUIDs.
    private func userInterfaceName(in sections: [UEFINode]) -> String? {
        for section in sections where section.kind == .section {
            if section.subtype == Section.userInterface,
               let text = ucs2String(in: section.body) {
                return text
            }
            if let nested = userInterfaceName(in: section.children) {
                return nested
            }
        }
        return nil
    }

    /// §5.2, where the header's own size depends on a bit whose meaning depends
    /// on the volume. Nil size means the extended field is off the end of the
    /// image.
    private func fileSize(
        at offset: UInt64,
        shortSize: UInt32,
        attributes: UInt8,
        ffsVersion: Int,
        volumeRevision: UInt8
    ) -> (headerSize: UInt64, size: UInt64?) {
        let isLarge = attributes & FFS.largeFile != 0
        if ffsVersion == 3 && isLarge {
            return (FFS.largeHeaderSize, reader.uint64(at: offset + 0x18))
        }
        if ffsVersion == 2 && volumeRevision == 2 && isLarge {
            return (FFS.lenovoHeaderSize, reader.uint32(at: offset + 0x18).map(UInt64.init))
        }
        return (FFS.headerSize, UInt64(shortSize))
    }

    /// The header sum leaves out the two checksum bytes and the state byte,
    /// because those are written after it is computed and changed again every
    /// time the file is marked (§5.4).
    private func verifyFileChecksums(
        at offset: UInt64,
        headerSize: UInt64,
        body: Range<UInt64>,
        headerChecksum: UInt8,
        bodyChecksum: UInt8,
        attributes: UInt8,
        volumeRevision: UInt8
    ) {
        if let header = reader.bytes(at: offset, count: headerSize),
           let state = reader.uint8(at: offset + 0x17) {
            let sum = Checksums.sum8(header) &- headerChecksum &- bodyChecksum &- state
            let computed = 0 &- sum
            if computed != headerChecksum {
                note(
                    .checksumMismatch(
                        .fileHeader,
                        stored: UInt64(headerChecksum),
                        computed: UInt64(computed)
                    ),
                    at: offset + 0x10
                )
            }
        }

        guard !body.isEmpty else { return }
        let computed: UInt8
        if attributes & FFS.checksumBit != 0 {
            guard let sum = Checksums.sum8(of: body, in: reader) else { return }
            computed = 0 &- sum
        } else {
            computed = volumeRevision == 1 ? FFS.fixedChecksum : FFS.fixedChecksum2
        }
        if computed != bodyChecksum {
            note(
                .checksumMismatch(
                    .fileBody,
                    stored: UInt64(bodyChecksum),
                    computed: UInt64(computed)
                ),
                at: offset + 0x11
            )
        }
    }
}

extension FFS {
    /// §5.6. Unknown codes keep their number, which is the only thing there is
    /// to say about a vendor type nobody documented.
    static func typeName(_ type: UInt8) -> String {
        switch type {
        case 0x01: return "Raw"
        case 0x02: return "Freeform"
        case 0x03: return "Security core"
        case 0x04: return "PEI core"
        case 0x05: return "DXE core"
        case 0x06: return "PEIM"
        case 0x07: return "Driver"
        case 0x08: return "Combined PEIM/driver"
        case 0x09: return "Application"
        case 0x0A: return "MM module"
        case 0x0B: return "Volume image"
        case 0x0C: return "Combined MM/DXE"
        case 0x0D: return "MM core"
        case 0x0E: return "MM standalone"
        case 0x0F: return "MM core standalone"
        case padType: return "Pad file"
        case 0xC0...0xDF: return "OEM file"
        case 0xE0...0xEF: return "Debug file"
        default: return String(format: "File type 0x%02X", type)
        }
    }
}
