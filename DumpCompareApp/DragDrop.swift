import Cocoa

/// The targeted drop destinations in single-file mode (§4.3, amended by §22.4).
/// The "this file" half is divided into three horizontal bands — the two join
/// strips at the top and bottom, and the replace band in the middle — and the
/// "second file" half is the single Open-as-Second target.
enum SingleFileDropTarget {
    case insertAtStart
    case replace
    case appendAtEnd
    case addSecond

    var title: String {
        switch self {
        case .insertAtStart: return "Insert at Start"
        case .replace: return "Replace Current File"
        case .appendAtEnd: return "Append at End"
        case .addSecond: return "Open as Second File"
        }
    }

    /// A join band (insert / append) brings the file's bytes into the pane
    /// rather than replacing it (§22.4).
    var isJoin: Bool {
        switch self {
        case .insertAtStart, .appendAtEnd: return true
        case .replace, .addSecond: return false
        }
    }
}

/// The layout of the three bands inside one pane's half of the drop overlay
/// (§22.4): the two join strips at the top and bottom, sized 25 % of the half's
/// height each and clamped to 48…120 pt, and the replace band filling the
/// middle. Pure — the hit-testing is testable at several pane heights without a
/// view. All y's are top-down within the half (0 at the half's top edge).
struct DropBandLayout {
    /// The half's full height, top-down.
    let halfHeight: CGFloat

    /// The join strip's height: 25 % of the half, clamped to 48…120 pt so the
    /// strips stay hittable in a short window and do not swallow the middle in
    /// a tall one (§22.4).
    var stripHeight: CGFloat { min(120, max(48, halfHeight * 0.25)) }

    /// The middle (replace) band's top-down range; empty when the half is too
    /// short for the two clamped strips to leave room for it.
    var replaceRange: Range<CGFloat> {
        let lower = stripHeight
        let upper = halfHeight - stripHeight
        return lower < upper ? lower ..< upper : lower ..< lower
    }

    /// Which band a top-down y within the half maps to, or nil outside it (a
    /// drop outside any band changes nothing, §22.4).
    func band(atTopDownY y: CGFloat) -> SingleFileDropTarget? {
        guard y >= 0, y < halfHeight else { return nil }
        if y < stripHeight { return .insertAtStart }
        if y >= halfHeight - stripHeight { return .appendAtEnd }
        return .replace
    }
}

extension NSPasteboard {
    /// File URLs offered by the pasteboard, or empty when none are present.
    /// `NSURL` reading is the modern path; the legacy "NSFilenamesPboardType"
    /// covers older drag sources (some Finder/configurators).
    var droppedFileURLs: [URL] {
        if let urls = readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls
        }
        if let names = propertyList(forType: NSPasteboard.PasteboardType.fileNames) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}

extension NSPasteboard.PasteboardType {
    /// Legacy Finder drag-and-drop file list type.
    static let fileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
}
