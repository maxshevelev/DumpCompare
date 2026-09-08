import Foundation

/// One element of a firmware image: a volume, a file, a section, a stretch of
/// padding (`Design/UEFI/UEFI_IMAGE_FORMAT.md`, "Рекомендуемая модель данных").
///
/// A node is *ranges of the image*, never bytes. Nothing here copies the file:
/// a 32 MiB image parses into a few thousand nodes holding three ranges each,
/// and anyone who wants the bytes reads them back through the same
/// `ImageReader`. That is also what keeps the model honest for an editor —
/// a node says where a structure is, so writing to it is writing to the file
/// rather than to a copy of it that has to be put back.
///
/// `header` / `body` / `tail` are contiguous and non-overlapping, and the split
/// is the whole shape of this format: almost every level is a header followed
/// by a body that the next level parses. `tail` is used only by FFSv1 files
/// with `FFS_ATTRIB_TAIL_PRESENT` and is empty everywhere else.
public struct UEFINode: Identifiable, Hashable, Sendable {
    /// Where the node sits in the tree. Stamped by `UEFIImage` once the tree is
    /// built, so the parser never has to carry a counter around.
    public var id: NodeID
    public var kind: UEFINodeKind
    /// The format's own type byte, read according to `kind`: an FFS file type
    /// for a file, a section type for a section. Untyped on purpose — these are
    /// one-byte codes with vendor ranges and unknown values, and turning an
    /// unknown code into a case would lose the number worth showing.
    public var subtype: UInt8?
    /// What to call it on screen. The parser fills in the best it has: a
    /// user-interface section's string, a known GUID's name, or the type.
    public var name: String
    /// A volume's file system, a file's name, a section's definition GUID.
    public var guid: EFIGUID?

    public var header: Range<UInt64>
    public var body: Range<UInt64>
    public var tail: Range<UInt64>

    /// Cannot be moved when the image is rebuilt (§11): the VTF, whatever FIT
    /// points at, anything a Boot Guard range covers, a file marked
    /// `FFS_ATTRIB_FIXED`.
    public var isFixed: Bool
    /// Lies inside a compressed container, so its absolute address means
    /// nothing — the decompressor puts it wherever it likes. Every address
    /// check skips these.
    public var isCompressed: Bool
    /// Nothing but the erase byte: free space, or padding that was never used.
    public var isErased: Bool

    public var children: [UEFINode]

    public init(
        id: NodeID = .root,
        kind: UEFINodeKind,
        subtype: UInt8? = nil,
        name: String,
        guid: EFIGUID? = nil,
        header: Range<UInt64>,
        body: Range<UInt64>,
        tail: Range<UInt64>? = nil,
        isFixed: Bool = false,
        isCompressed: Bool = false,
        isErased: Bool = false,
        children: [UEFINode] = []
    ) {
        self.id = id
        self.kind = kind
        self.subtype = subtype
        self.name = name
        self.guid = guid
        self.header = header
        self.body = body
        self.tail = tail ?? (body.upperBound..<body.upperBound)
        self.isFixed = isFixed
        self.isCompressed = isCompressed
        self.isErased = isErased
        self.children = children
    }

    /// A node with no header of its own — padding, free space, data nobody
    /// claimed. All body.
    public init(
        kind: UEFINodeKind,
        name: String,
        range: Range<UInt64>,
        isErased: Bool = false
    ) {
        self.init(
            kind: kind,
            name: name,
            header: range.lowerBound..<range.lowerBound,
            body: range,
            isErased: isErased
        )
    }

    /// Everything the node covers, header through tail.
    public var range: Range<UInt64> {
        let end = max(header.upperBound, max(body.upperBound, tail.upperBound))
        return header.lowerBound..<max(header.lowerBound, end)
    }

    /// This node and all of its descendants, outermost first — the order a
    /// reader meets them in.
    public var flattened: [UEFINode] {
        [self] + children.flatMap(\.flattened)
    }

    /// Hashed by `id` alone, and deliberately not by anything else.
    ///
    /// `Hashable` is here for `NSOutlineView`, which is handed nodes as its
    /// items. An item has to be an object, so each one is bridged into a fresh
    /// box, and the outline's item map keys those boxes by `hash` and
    /// `isEqual:`. A Swift value with no `Hashable` conformance gets an
    /// identity hash from the bridge, so two boxes over the same node land in
    /// different buckets and every lookup degrades into a linear scan —
    /// invisible while expanding, which only inserts, and a stall while
    /// collapsing, which has to find and drop every descendant. Measured on a
    /// 400-child NVRAM store: 1.28 s to collapse without this, 0.00 s with it.
    ///
    /// `id` is the whole hash because it already identifies the node in the
    /// tree, and because the synthesized alternative would walk `children` —
    /// hashing a subtree on every lookup, which is the cost this is here to
    /// avoid. Equal nodes agree on `id`, so this stays consistent with the
    /// synthesized `==`.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// What an element *is*. No associated values: the fields behind each kind stay
/// in the image, where a consumer that wants `Attributes` can read them through
/// the reader it already has. What the tree carries is the structure — which is
/// the part that costs a parse to work out.
public enum UEFINodeKind: String, Equatable, Sendable, CaseIterable {
    case capsule
    /// The whole of an Intel flash image: a descriptor and the regions it maps,
    /// under one root the way UEFITool shows it (§2.2). Its body is the whole
    /// image and its children are the descriptor and regions laid out in it.
    case intelImage
    case flashDescriptor
    case region
    case volume
    case file
    case section
    case microcode
    /// The stores an NVRAM volume body is read as (§9). Each is a distinct kind
    /// because the tree's Type column is keyed by kind and no byte on the node
    /// says which store it is — the parser matched a signature to know.
    case vssStore
    case vss2Store
    case ftwStore
    case fdcStore
    case sysFStore
    case flashMapStore
    case evsaStore
    case cmdbStore
    case slicData
    /// A variable or entry inside one of those stores.
    case vssEntry
    case sysFEntry
    case evsaEntry
    case flashMapEntry
    /// Space between elements that belongs to no structure.
    case padding
    /// The unused tail of a volume's body (§5.8).
    case freeSpace
    /// Bytes inside a volume that are not an FFS file and not free space.
    case nonUEFIData
}

/// Where a node sits in the tree, as the path of child indices from the root.
///
/// Not an offset: two parses of the same image give the same paths, a path
/// survives being written down in a zone id, and it reads back as a route —
/// which is what a diagnostic about a node three levels down needs to say.
public struct NodeID: Hashable, Sendable, CustomStringConvertible {
    public var path: [Int]

    public init(_ path: [Int] = []) {
        self.path = path
    }

    public static let root = NodeID()

    public func child(_ index: Int) -> NodeID {
        NodeID(path + [index])
    }

    public var description: String {
        path.isEmpty ? "root" : path.map(String.init).joined(separator: ".")
    }
}
