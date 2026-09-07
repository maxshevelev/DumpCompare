import AppKit
import ToolModuleKit
import UEFIContentSource
import UEFIImage
import UEFITool

/// The structure of a UEFI firmware image, read and shown
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// A bench opens a dump and wants to see what is in it — the volumes, the files
/// in them, the sections in those — and, for the one node it is looking at,
/// where it is and what its header says. It answers by reading, never by
/// assuming: the tree is the parser's, and the detail is the node's header read
/// back through the same reader.
public enum UEFIToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.uefi-structure"
    public static let title = "UEFI Structure"
    /// A tree of names and a list of label/value fields: less room than the
    /// FIT table's six columns, more than the minimap's 120.
    public static let preferredPanelWidth: CGFloat = 420

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        UEFIToolSession(host: host)
    }
}

/// What a parked session hands back: the node the user was looking at, and
/// nothing else. The parse is worth doing again — it is milliseconds — and a
/// tree of thousands of nodes per parked tool-module is how an app comes to
/// hold four copies of an image it is not showing (`ToolSession.parkedState`).
struct UEFIParkedState: ToolSessionState {
    var focus: NodeID?
}

/// The running instrument: parse off the main actor, show the tree, publish the
/// one zone for the node in focus, and say what that node is.
@MainActor public final class UEFIToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = UEFIToolViewController()

    /// The parsed image and the reader over the snapshot it was parsed from.
    /// Kept together: the detail reads headers through the same bytes the tree
    /// came from, so the two cannot drift apart.
    private var image: UEFIImage?
    private var reader: ImageReader?
    /// The node the user is looking at. Nil before a choice, and after a
    /// re-parse that lost it.
    private var focus: NodeID?
    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0

    /// Called on the main actor once a parse has landed and the panel has been
    /// shown. The parse runs off the main actor, so a test that waited for it
    /// on the clock would be a test that fails on a busy machine.
    public var onDisplay: ((UEFIImage?) -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] nodeID in self?.select(nodeID) }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        controller.say("Reading…")
        reparse()
    }

    /// Any change is a reason to read again. The tree is cheap to rebuild and
    /// expensive to keep in sync, so a re-parse is the honest answer to every
    /// edit — and the selection is kept by path, so it survives a re-parse of
    /// the same image and is dropped when the node is gone.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {}

    public var parkedState: (any ToolSessionState)? { UEFIParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? UEFIParkedState else { return }
        focus = state.focus
    }

    // MARK: - Reading

    private func reparse() {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            image = nil
            reader = nil
            controller.say("Could not read the file: \(error)", asProblem: true)
            show()
            return
        }

        let source = ToolContentByteSource(reader: snapshot)
        generation += 1
        let generation = self.generation
        controller.showBusy()
        let reporter = progressReporter()
        Task { [weak self] in
            let parsed = await UEFIToolSession.parse(source, progress: reporter)
            guard let self, self.generation == generation else { return }
            self.image = parsed
            self.reader = ImageReader(source)
            self.controller.endBusy()
            self.show()
            self.onDisplay?(self.image)
        }
    }

    /// What a parse reports through: a hop back to the main actor that lands on
    /// the module's own bottom-row bar. Built per parse, so the detached task
    /// only ever moves the bar of the parse it ran.
    private func progressReporter() -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.controller.updateProgress(fraction) }
        }
    }

    /// Off the main actor: a 16 MiB image is a full UEFI parse, and the panel
    /// is on screen while it runs.
    private nonisolated static func parse(
        _ source: any ByteSource,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> UEFIImage {
        await Task.detached(priority: .userInitiated) {
            UEFIParser.parse(source, progress: progress)
        }.value
    }

    /// Everything the panel shows, in one call: the tree, the detail for the
    /// node in focus, and the one zone that node publishes.
    private func show() {
        guard let image, let reader else {
            controller.show(image: nil, focus: nil, detail: .empty)
            host.publish(.empty)
            return
        }
        let node = focus.flatMap { image.node($0) }
        let detail = node.map { UEFIDetail.build(for: $0, image: image, reader: reader) } ?? .empty
        controller.show(image: image, focus: focus, detail: detail)
        host.publish(UEFIPresenter.zones(for: node))
    }

    // MARK: - What the panel asks for

    /// The user picked a node in the tree. Publishing again is what moves the
    /// outline in the dump, and the host brings a newly focused zone on screen
    /// by itself.
    private func select(_ nodeID: NodeID?) {
        focus = nodeID
        show()
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the node it stands for to the front —
    /// expand the tree to it and select it, which is the half only this side
    /// knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        guard let nodeID = UEFIPresenter.nodeID(ofZone: id) else { return }
        focus = nodeID
        show()
    }
}
