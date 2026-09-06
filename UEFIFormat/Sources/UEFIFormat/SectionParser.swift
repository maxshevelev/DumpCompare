import Foundation

/// `EFI_COMMON_SECTION_HEADER` and the section types (§6).
enum Section {
    static let headerSize: UInt64 = 4
    /// FFSv3 only: a size of `0xFFFFFF` means the real one follows in 32 bits.
    static let extendedHeaderSize: UInt64 = 8
    static let extendedSizeMarker: UInt32 = 0xFF_FFFF
    /// Sections sit on four-byte boundaries, where files sit on eight.
    static let alignment: UInt64 = 4

    static let compression: UInt8 = 0x01
    static let guidDefined: UInt8 = 0x02
    static let disposable: UInt8 = 0x03
    static let userInterface: UInt8 = 0x15
    static let firmwareVolumeImage: UInt8 = 0x17
    static let raw: UInt8 = 0x19

    /// `EFI_COMPRESSION_SECTION`, which follows the common header.
    static let compressionHeaderSize: UInt64 = 5
    static let notCompressed: UInt8 = 0x00

    /// `EFI_GUID_DEFINED_SECTION`: a GUID, a `DataOffset` and attributes.
    static let guidDefinedHeaderSize: UInt64 = 20

    /// §6.1. A vendor type nobody documented keeps its number.
    static func typeName(_ type: UInt8) -> String {
        switch type {
        case compression: return "Compressed section"
        case guidDefined: return "GUID-defined section"
        case disposable: return "Disposable section"
        case 0x10: return "PE32 image"
        case 0x11: return "PIC image"
        case 0x12: return "TE image"
        case 0x13: return "DXE dependency"
        case 0x14: return "Version"
        case userInterface: return "Name"
        case 0x16: return "Compatibility16"
        case firmwareVolumeImage: return "Volume image"
        case 0x18: return "Freeform subtype GUID"
        case raw: return "Raw"
        case 0x1B: return "PEI dependency"
        case 0x1C: return "MM dependency"
        case 0x20: return "Insyde postcode"
        case 0xF0: return "Phoenix postcode"
        default: return String(format: "Section type 0x%02X", type)
        }
    }

    static func isKnown(_ type: UInt8) -> Bool {
        // 0x1A is not a section type. The gap is the specification's, and a
        // range that papers over it would wave through the one value in here
        // that means something is wrong.
        (0x01...0x03).contains(type) || (0x10...0x19).contains(type)
            || type == 0x1B || type == 0x1C || type == 0x20 || type == 0xF0
    }
}

extension Parser {
    /// A file's body, read as the run of sections it is (§6).
    ///
    /// Encapsulating sections are where the tree stops being a list: a
    /// compression section holds sections, a volume image section holds a
    /// volume, and the volume holds files again. What this parser will not do
    /// is decompress — five algorithms, none of them in the system libraries,
    /// and the rule of this project is no third-party code. A compressed
    /// section is a leaf that says which algorithm it is, and the day one is
    /// implemented it grows children instead.
    func walkSections(
        _ body: Range<UInt64>,
        ffsVersion: Int,
        emptyByte: UInt8,
        depth: Int
    ) -> [UEFINode] {
        guard depth < limits.maxDepth else {
            note(.recursionLimit, at: body.lowerBound)
            return []
        }
        var nodes: [UEFINode] = []
        var offset = body.lowerBound

        while offset < body.upperBound {
            guard body.upperBound - offset >= Section.headerSize else {
                nodes += padding(from: offset, to: body.upperBound, emptyByte: emptyByte)
                break
            }
            guard let shortSize = reader.uint24(at: offset),
                  let type = reader.uint8(at: offset + 3)
            else {
                nodes += padding(from: offset, to: body.upperBound, emptyByte: emptyByte)
                break
            }

            var headerSize = Section.headerSize
            var size = UInt64(shortSize)
            if shortSize == Section.extendedSizeMarker && ffsVersion == 3 {
                guard let extended = reader.uint32(at: offset + 4) else {
                    note(.truncated(.sectionHeader), at: offset)
                    break
                }
                headerSize = Section.extendedHeaderSize
                size = UInt64(extended)
            }
            guard size != 0 else {
                note(.zeroSize(.sectionHeader), at: offset)
                break
            }
            guard size >= headerSize else {
                note(.sizeMismatch(.sectionHeader, stored: size, computed: headerSize), at: offset)
                break
            }

            var end = offset + size
            if end > body.upperBound {
                note(.truncated(.sectionBody), at: offset)
                end = body.upperBound
                guard end - offset > headerSize else { break }
            }

            nodes.append(parseSection(
                at: offset, end: end, headerSize: headerSize, type: type,
                ffsVersion: ffsVersion, emptyByte: emptyByte, depth: depth
            ))

            guard let next = alignUp(end - body.lowerBound, to: Section.alignment)
                .map({ body.lowerBound + $0 }), next > offset
            else { break }
            nodes += padding(from: end, to: min(next, body.upperBound), emptyByte: emptyByte)
            offset = next
        }
        return nodes
    }

    private func parseSection(
        at offset: UInt64,
        end: UInt64,
        headerSize: UInt64,
        type: UInt8,
        ffsVersion: Int,
        emptyByte: UInt8,
        depth: Int
    ) -> UEFINode {
        var name = Section.typeName(type)
        var guid: EFIGUID?
        var bodyStart = offset + headerSize
        var readsBodyAsSections = false

        switch type {
        case Section.disposable:
            readsBodyAsSections = true

        case Section.compression:
            bodyStart = min(offset + headerSize + Section.compressionHeaderSize, end)
            if let algorithm = reader.uint8(at: offset + headerSize + 4) {
                readsBodyAsSections = algorithm == Section.notCompressed
                name = compressionName(algorithm)
            }

        case Section.guidDefined:
            guid = reader.guid(at: offset + headerSize)
            // The body starts where the section says it does, not where the
            // structure ends: vendors put certificates and their own headers in
            // between, and `DataOffset` is the only thing that knows (§6.3).
            if let dataOffset = reader.uint16(at: offset + headerSize + 16),
               UInt64(dataOffset) >= headerSize + Section.guidDefinedHeaderSize,
               offset + UInt64(dataOffset) <= end {
                bodyStart = offset + UInt64(dataOffset)
            } else {
                bodyStart = min(offset + headerSize + Section.guidDefinedHeaderSize, end)
            }
            if let guid, let known = KnownGUIDs.guidedSection(guid) {
                name = "\(known.name) section"
                readsBodyAsSections = !known.transformsBody
            }

        default:
            if !Section.isKnown(type) {
                note(.unknownType(.sectionHeader, type), at: offset + 3)
            }
        }

        let body = bodyStart..<end
        var children: [UEFINode] = []
        if !body.isEmpty {
            if readsBodyAsSections {
                children = walkSections(
                    body, ffsVersion: ffsVersion, emptyByte: emptyByte, depth: depth + 1
                )
            } else if type == Section.firmwareVolumeImage {
                // A volume inside a section, and files inside that: the point at
                // which this format starts over one level down (§6.4).
                if let volume = parseVolume(at: bodyStart, limit: end, depth: depth + 1) {
                    children = [volume]
                }
            } else if type == Section.userInterface, let text = ucs2String(in: body) {
                name = text
            }
        }

        return UEFINode(
            kind: .section,
            subtype: type,
            name: name,
            guid: guid,
            header: offset..<bodyStart,
            body: body,
            children: children
        )
    }

    private func compressionName(_ algorithm: UInt8) -> String {
        switch algorithm {
        case Section.notCompressed: return "Uncompressed section"
        case 0x01: return "Tiano compressed section"
        case 0x02: return "Customized compressed section"
        case 0x86: return "LZMA with x86 filter section"
        default: return String(format: "Compressed section (type 0x%02X)", algorithm)
        }
    }

    /// A user-interface section is a UCS-2 string with a terminating zero
    /// (§6.4) — the name a person gave the file, and the only readable name
    /// most files have.
    func ucs2String(in range: Range<UInt64>) -> String? {
        guard let bytes = reader.bytes(range), bytes.count >= 2 else { return nil }
        var units: [UInt16] = []
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        let text = String(decoding: units, as: UTF16.self)
        return text.isEmpty ? nil : text
    }
}
