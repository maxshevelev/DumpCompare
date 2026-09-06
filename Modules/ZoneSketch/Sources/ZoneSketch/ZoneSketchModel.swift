import Foundation
import ToolModuleKit

/// The zones the user has sketched, and everything decided about them.
///
/// No AppKit and no host: the view controller over it holds one of these and
/// asks it questions. That is the shape every tool-module is meant to have —
/// what can be decided without a window is decided here, and tested in a
/// second rather than through one (`Design/TOOL_MODULES_PLAN.md`).
public struct ZoneSketchModel: Equatable, Sendable {
    /// In the order they were made, which is the order the list shows. The
    /// published map is sorted for drawing; this is the user's own order.
    public private(set) var zones: [Zone] = []
    /// The row the panel has selected, which is also the zone drawn as focused.
    public private(set) var focus: Zone.ID?

    /// How many zones have ever been made here, so a name is never reused
    /// within one session even after removals.
    private var made = 0

    public init() {}

    /// The map to publish: what the dump should draw, focus included.
    public var map: ZoneMap { ZoneMap(zones: zones, focus: focus) }

    public var focused: Zone? { zones.first { $0.id == focus } }

    /// Adds a zone over `range`, names it, and focuses it.
    ///
    /// An empty or backwards range makes nothing: a zone is a stretch, and the
    /// caller (a button reading the pane's selection) can be pointed at a
    /// caret rather than a span.
    @discardableResult
    public mutating func add(_ range: Range<UInt64>, named name: String? = nil) -> Zone? {
        guard range.lowerBound < range.upperBound else { return nil }
        made += 1
        let zone = Zone(id: "sketch-\(made)",
                        name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Zone \(made)",
                        range: range)
        zones.append(zone)
        focus = zone.id
        return zone
    }

    public mutating func remove(_ id: Zone.ID) {
        zones.removeAll { $0.id == id }
        if focus == id { focus = zones.last?.id }
    }

    public mutating func removeAll() {
        zones.removeAll()
        focus = nil
    }

    /// Renames a zone. An empty name is refused rather than stored: a row that
    /// says nothing is worse than one that says "Zone 3".
    public mutating func rename(_ id: Zone.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = zones.firstIndex(where: { $0.id == id }) else { return }
        zones[index].name = trimmed
    }

    /// Focuses a zone, or nothing. An id nothing answers to clears the focus
    /// rather than leaving it pointing at a zone that has gone.
    public mutating func focus(_ id: Zone.ID?) {
        focus = id.flatMap { candidate in zones.contains { $0.id == candidate } ? candidate : nil }
    }

    /// The transaction that fills the focused zone with `byte`, or nil when
    /// there is nothing focused. Named for the menu: "Undo Fill Zone 2".
    public func fillFocused(with byte: UInt8) -> ToolTransaction? {
        guard let zone = focused else { return nil }
        let count = Int(zone.range.upperBound - zone.range.lowerBound)
        return ToolTransaction(name: "Fill \(zone.name)",
                               offset: zone.range.lowerBound,
                               bytes: [UInt8](repeating: byte, count: count))
    }

    /// What a zone's bytes would be saved as.
    public func exportName(of zone: Zone, in fileName: String) -> String {
        let base = fileName.isEmpty ? "dump" : fileName
        let start = String(format: "%08llX", zone.range.lowerBound)
        return "\(base)_\(start)_\(zone.name).bin"
    }

    /// The offsets a zone covers, as the list shows them.
    public static func rangeText(_ range: Range<UInt64>) -> String {
        String(format: "%llX – %llX", range.lowerBound, range.upperBound - 1)
    }
}

/// The sketch is the whole of what this tool-module knows, so parking its state
/// is parking the model — nothing is re-derived, because nothing was derived.
/// A tool-module with a parse behind it would park much less than this
/// (`ToolSession.parkedState`).
extension ZoneSketchModel: ToolSessionState {}
