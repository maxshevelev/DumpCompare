import AppKit
import ToolModuleKit
import ZoneSketch

/// A tool-module for marking zones by hand
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// It parses nothing. What it is for is the seam: a real tool-module, in its
/// own package, that publishes zones and focuses them, navigates to one, writes
/// through a transaction and exports bytes — so the panel, the outlines in the
/// dump, the named undo step and the file panels can all be tried on a real
/// dump before any parser exists to produce a map.
///
/// It is also useful on its own: marking out the regions of an unfamiliar image
/// by hand is what a bench does with a pencil today.
public enum ZoneSketchModule: ToolModule {
    public static let identifier = "dev.maxik.tool.zonesketch"
    public static let title = "Zone Sketch"
    public static let preferredPanelWidth: CGFloat = 320

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        ZoneSketchSession(host: host)
    }
}

/// The running instrument: the model, the view controller over it, and the
/// rule that the two are kept in step by publishing after every change.
@MainActor public final class ZoneSketchSession: ToolSession {
    private let host: any ToolHost
    private let controller: ZoneSketchViewController
    private var model = ZoneSketchModel()

    public init(host: any ToolHost) {
        self.host = host
        controller = ZoneSketchViewController()
        controller.onAdd = { [weak self] in self?.addFromSelection() }
        controller.onRemove = { [weak self] id in self?.remove(id) }
        controller.onFocus = { [weak self] id in self?.focus(id) }
        controller.onRename = { [weak self] id, name in self?.rename(id, to: name) }
        controller.onGoTo = { [weak self] id in self?.goTo(id) }
        controller.onFill = { [weak self] in self?.fill() }
        controller.onExport = { [weak self] in self?.export() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        refresh()
    }

    /// The file changed under the sketch. Nothing is re-read — there is nothing
    /// to re-read — but the map is republished so the host can clamp it to a
    /// file that may have shrunk, and the list follows.
    public func contentChanged(_ change: ToolContentChange) {
        refresh()
    }

    public func stop() {}

    /// The user picked one of the sketched zones in the dump. Selecting the row
    /// is the whole of what this tool can add to that — but it is the thing
    /// that makes the panel and the dump feel like one surface rather than two.
    public func zoneSelected(_ id: Zone.ID) {
        focus(id)
    }

    /// The zones outlive the panel being switched away from: the user drew
    /// them, and losing hand-made work to a menu click is the one thing a
    /// sketch must not do. The names go with them — `made` is part of the
    /// model — so coming back does not start numbering at one again.
    public var parkedState: (any ToolSessionState)? { model }

    public func restore(_ state: any ToolSessionState) {
        guard let model = state as? ZoneSketchModel else { return }
        self.model = model
    }

    // MARK: - What the buttons do

    private func addFromSelection() {
        // The selection if there is one, else a mouthful at the caret — a
        // button that does nothing when nothing is selected teaches nobody
        // anything.
        let range = host.selection ?? host.caret..<min(host.caret + 16, host.contentSize)
        guard model.add(range) != nil else {
            controller.say("Put the caret somewhere in the dump first.")
            return
        }
        refresh()
    }

    private func remove(_ id: Zone.ID) {
        model.remove(id)
        refresh()
    }

    private func focus(_ id: Zone.ID?) {
        model.focus(id)
        refresh()
    }

    private func rename(_ id: Zone.ID, to name: String) {
        model.rename(id, to: name)
        refresh()
    }

    private func goTo(_ id: Zone.ID) {
        model.focus(id)
        refresh()
        guard let zone = model.focused else { return }
        host.reveal(zone.range, select: true)
    }

    private func fill() {
        guard let transaction = model.fillFocused(with: 0xFF) else { return }
        do {
            try host.apply(transaction)
            controller.say("Filled \(model.focused?.name ?? "the zone") with FF. ⌘Z takes it back.")
        } catch {
            controller.say("Could not write: \(error)")
        }
    }

    private func export() {
        guard let zone = model.focused else { return }
        let name = model.exportName(of: zone, in: host.fileName)
        Task { [host, model] in
            guard let bytes = try? host.read(zone.range) else { return }
            _ = await host.exportFile(bytes, suggestedName: name)
            _ = model
        }
    }

    /// The one place the model reaches the outside: the list and the dump are
    /// both drawn from it, after every change, so they cannot disagree.
    private func refresh() {
        controller.show(model.zones, focus: model.focus, canWrite: !host.isReadOnly)
        host.publish(model.map)
    }
}
