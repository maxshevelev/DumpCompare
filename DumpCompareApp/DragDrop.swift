import Cocoa

/// The two targeted drop destinations in single-file mode (§4.3): replacing the
/// current file, or opening the dropped file(s) as a second file.
enum SingleFileDropTarget {
    case replace
    case addSecond

    var title: String {
        switch self {
        case .replace: return "Replace Current File"
        case .addSecond: return "Open as Second File"
        }
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
