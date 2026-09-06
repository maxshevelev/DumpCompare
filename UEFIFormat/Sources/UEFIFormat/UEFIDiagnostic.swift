import Foundation

/// Something wrong with the image, reported rather than thrown.
///
/// A dump off a real flash chip almost always has one structure that does not
/// match the specification (§11), so a parser that throws on the first one
/// parses nothing anyone owns. Every level here collects and carries on, and
/// what it collects is the interesting half of the output: the reason to open a
/// tool-module on an image is usually that something in it is already wrong.
///
/// A diagnostic locates itself by offset and not by node id, because it is
/// raised while the node is still being built — and an offset is the better
/// answer anyway: `UEFIImage.nodes(containing:)` turns it back into the node,
/// and the dump can put the caret on it.
public struct UEFIDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable {
        /// The value is wrong but the parse went on.
        case warning
        /// Parsing this level stopped here.
        case error
    }

    /// The structure being read when the trouble showed up.
    public enum Structure: String, Sendable {
        case capsuleHeader
        case flashDescriptor
        case volumeHeader
        case volumeExtendedHeader
        case volumeBody
        case fileHeader
        case fileBody
        case sectionHeader
        case sectionBody
        case microcodeHeader
        case resetVector
    }

    public enum Kind: Equatable, Sendable {
        /// The image ends before the structure does.
        case truncated(Structure)
        /// A size field of zero, which would loop forever if believed (§11).
        case zeroSize(Structure)
        case checksumMismatch(Structure, stored: UInt64, computed: UInt64)
        case sizeMismatch(Structure, stored: UInt64, computed: UInt64)
        /// A volume whose file system GUID is not one we parse; its body is
        /// kept whole rather than read as FFS (§3.4).
        case unknownFileSystem(EFIGUID)
        case unknownType(Structure, UInt8)
        /// A tree deep enough to be a loop rather than an image (§11).
        case recursionLimit
        /// No Volume Top File, so no addresses, so no second pass (§5.7).
        case noVolumeTopFile

        public var severity: Severity {
            switch self {
            case .truncated, .zeroSize, .recursionLimit:
                return .error
            case .checksumMismatch, .sizeMismatch, .unknownFileSystem,
                 .unknownType, .noVolumeTopFile:
                return .warning
            }
        }
    }

    public var kind: Kind
    /// Where in the image, absolute.
    public var offset: UInt64

    public init(_ kind: Kind, at offset: UInt64) {
        self.kind = kind
        self.offset = offset
    }

    public var severity: Severity { kind.severity }

    /// One line, for a tool-module's own list. The host never sees these — where
    /// a tool-module's diagnostics go is its panel (`Design/TOOL_MODULES_PLAN.md`).
    public var message: String {
        switch kind {
        case .truncated(let structure):
            return "\(structure.label) runs past the end of the image"
        case .zeroSize(let structure):
            return "\(structure.label) has a size of zero"
        case .checksumMismatch(let structure, let stored, let computed):
            return "\(structure.label) checksum is \(hex(stored)), computed \(hex(computed))"
        case .sizeMismatch(let structure, let stored, let computed):
            return "\(structure.label) size is \(hex(stored)), computed \(hex(computed))"
        case .unknownFileSystem(let guid):
            return "unknown volume file system \(guid)"
        case .unknownType(let structure, let code):
            return "unknown \(structure.label) type \(hex(UInt64(code)))"
        case .recursionLimit:
            return "nesting is too deep to be an image"
        case .noVolumeTopFile:
            return "no volume top file, so absolute addresses are unknown"
        }
    }

    private func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

extension UEFIDiagnostic.Structure {
    var label: String {
        switch self {
        case .capsuleHeader: return "capsule header"
        case .flashDescriptor: return "flash descriptor"
        case .volumeHeader: return "volume header"
        case .volumeExtendedHeader: return "volume extended header"
        case .volumeBody: return "volume body"
        case .fileHeader: return "file header"
        case .fileBody: return "file body"
        case .sectionHeader: return "section header"
        case .sectionBody: return "section body"
        case .microcodeHeader: return "microcode header"
        case .resetVector: return "reset vector"
        }
    }
}
