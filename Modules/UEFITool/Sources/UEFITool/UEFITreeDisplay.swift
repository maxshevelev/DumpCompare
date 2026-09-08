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

    /// The tree as it is shown: the outline's top level, and the node the
    /// summary stands for when one row has been taken out of the tree.
    ///
    /// A single root that is a *pure wrapper* — empty header, children of its
    /// own, never anything the format put there — holds the whole file and
    /// does no work as a row. Its one job in the tree is to say what the image
    /// is, so it is moved up into the panel title instead and its children
    /// become the top of the outline. The predicate is structural, never
    /// per-kind, so it covers the Intel image root and the UEFI image root
    /// alike — and a capsule (whose root has a header of its own) is left as a
    /// row, as is any file with several roots.
    public struct PresentedImage {
        /// The hidden wrapper the summary leads with, or nil when nothing was
        /// folded away.
        public let title: UEFINode?
        /// The outline's top level: the wrapper's children when there was a
        /// wrapper, the image's roots otherwise.
        public let rows: [UEFINode]

        public init(title: UEFINode?, rows: [UEFINode]) {
            self.title = title
            self.rows = rows
        }
    }

    public static func present(_ image: UEFIImage) -> PresentedImage {
        guard image.roots.count == 1, let root = image.roots.first,
              root.header.isEmpty, !root.children.isEmpty
        else { return PresentedImage(title: nil, rows: image.roots) }
        return PresentedImage(title: root, rows: root.children)
    }

    /// What the tree is, in one line: what the image is, and how much of it the
    /// tree accounts for.
    ///
    /// The image leads with the hidden wrapper's name — "UEFI image", "Intel
    /// image" — when `present` folded one into the title; otherwise it leads
    /// with the image type of the first root (`imageType(of:)`). Either way it
    /// is the same decision the outline shows, so the title and the tree agree.
    public static func summary(of image: UEFIImage?) -> String {
        guard let image else { return "" }
        let nodes = image.allNodes
        let count = nodes.count
        guard count > 0 else { return "Nothing here looks like a firmware image." }
        let volumes = nodes.filter { $0.kind == .volume }.count
        let files = nodes.filter { $0.kind == .file }.count
        var parts: [String] = []
        let presented = present(image)
        if let title = presented.title {
            if !title.name.isEmpty { parts.append(title.name) }
        } else {
            let imageType = imageType(of: image)
            if !imageType.isEmpty { parts.append(imageType) }
        }
        parts.append("\(count) " + (count == 1 ? "node" : "nodes"))
        if volumes > 0 { parts.append("\(volumes) volume" + (volumes == 1 ? "" : "s")) }
        if files > 0 { parts.append("\(files) file" + (files == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
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
        case .uefiImage: return "UEFI image"
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
