import Foundation
import UEFIImage

/// What the structure tree says about each node, decided here so the view
/// controller lays out text rather than choosing any of it
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The Type and Subtype columns read the node in UEFITool's classification —
/// the same `Types::ItemTypes` / `Subtypes` the `UEFITypes` tables mirror — and
/// the name comes from the GUID catalogue when the node has a GUID. All of it
/// is a function of the node and the catalogue, so it is testable without a
/// window.
public enum UEFITreeDisplay {
    /// The Type column: the node's item type, in UEFITool's words.
    public static func typeText(for node: UEFINode) -> String {
        UEFITypes.typeName(node.uefiItemType)
    }

    /// The Subtype column: the node's subtype, when it has one.
    ///
    /// `File` and `Section` are named from the FFS and section type tables the
    /// parser already uses — the C++ `itemSubtypeToUString` delegates them to
    /// `fileTypeToUString` / `sectionTypeToUString`, which are not in
    /// `types.cpp` — so a known type is a word and an unknown one keeps its
    /// number. Every other type reads from the generated `UEFITypes` tables.
    public static func subtypeText(for node: UEFINode) -> String {
        guard let subtype = node.uefiItemSubtype else { return "" }
        switch node.kind {
        case .file: return UEFITypeNames.file(subtype)
        case .section: return UEFITypeNames.section(subtype)
        default: return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? ""
        }
    }

    /// What the title leads with before the node count: the type of the top of
    /// the tree. A capsule file leads with its capsule, a dump with its first
    /// root — the same classification the columns show, so the title and the
    /// tree below it agree on what the image is.
    public static func imageType(of image: UEFIImage) -> String {
        guard let root = image.roots.first else { return "" }
        let type = typeText(for: root)
        let subtype = subtypeText(for: root)
        return subtype.isEmpty ? type : "\(type) · \(subtype)"
    }

    /// The name the tree shows for a node.
    ///
    /// A node with a GUID is named by the catalogue — the community's name for
    /// that GUID — and by the GUID itself while the catalogue has no name for
    /// it, which is the whole of the first paint before a download lands. A
    /// node without a GUID keeps the name the parser gave it, falling back to
    /// its kind when the parser had nothing to say.
    public static func name(for node: UEFINode, catalogue: GuidsCatalogue) -> String {
        guard let guid = node.guid else {
            return node.name.isEmpty ? kindLabel(node.kind) : node.name
        }
        // The community catalogue first; the NVRAM classifier names the GUIDs
        // it knows while the catalogue has no name for them; the GUID itself
        // is the last resort.
        return catalogue.name(of: guid) ?? NvramGuids.name(of: guid) ?? guid.description
    }

    private static func kindLabel(_ kind: UEFINodeKind) -> String {
        switch kind {
        case .capsule: return "Capsule"
        case .intelImage: return "Intel image"
        case .flashDescriptor: return "Flash descriptor"
        case .region: return "Region"
        case .volume: return "Volume"
        case .file: return "FFS file"
        case .section: return "Section"
        case .microcode: return "Microcode"
        // The NVRAM stores and entries read as their item-type word, so the
        // fallback name and the Type column can never drift apart.
        case .vssStore: return UEFITypes.typeName(UEFITypes.Item.vssStore.rawValue)
        case .vss2Store: return UEFITypes.typeName(UEFITypes.Item.vss2Store.rawValue)
        case .ftwStore: return UEFITypes.typeName(UEFITypes.Item.ftwStore.rawValue)
        case .fdcStore: return UEFITypes.typeName(UEFITypes.Item.fdcStore.rawValue)
        case .sysFStore: return UEFITypes.typeName(UEFITypes.Item.sysFStore.rawValue)
        case .flashMapStore: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapStore.rawValue)
        case .evsaStore: return UEFITypes.typeName(UEFITypes.Item.evsaStore.rawValue)
        case .cmdbStore: return UEFITypes.typeName(UEFITypes.Item.cmdbStore.rawValue)
        case .slicData: return UEFITypes.typeName(UEFITypes.Item.slicData.rawValue)
        case .vssEntry: return UEFITypes.typeName(UEFITypes.Item.vssEntry.rawValue)
        case .sysFEntry: return UEFITypes.typeName(UEFITypes.Item.sysFEntry.rawValue)
        case .evsaEntry: return UEFITypes.typeName(UEFITypes.Item.evsaEntry.rawValue)
        case .flashMapEntry: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapEntry.rawValue)
        case .padding: return "Padding"
        case .freeSpace: return "Free space"
        case .nonUEFIData: return "Non-UEFI data"
        }
    }
}
