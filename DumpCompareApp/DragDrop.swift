import Cocoa
import DumpCompareCore

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

    /// Height taken off the top by the window-level New Tab strip, which lies
    /// across every pane's overlay (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// The bands start below it and share what is left. Without this the strip
    /// and the top band would both claim the same points — and AppKit resolves a
    /// drop destination by frame among registered views rather than through
    /// `hitTest:`, so the disagreement would not be visible until a drop went
    /// somewhere nobody meant. Zero where there is no strip.
    var topInset: CGFloat = 0

    /// The height the bands actually divide: the half, less the strip's share.
    var bandHeight: CGFloat { max(0, halfHeight - topInset) }

    /// The join strip's height: 25 % of the band area, clamped to 48…120 pt so
    /// the strips stay hittable in a short window and do not swallow the middle
    /// in a tall one (§22.4).
    var stripHeight: CGFloat { min(120, max(48, bandHeight * 0.25)) }

    /// The middle (replace) band's top-down range, measured from the half's own
    /// top; empty when the half is too short for the two clamped strips to leave
    /// room for it.
    var replaceRange: Range<CGFloat> {
        let lower = topInset + stripHeight
        let upper = topInset + bandHeight - stripHeight
        return lower < upper ? lower ..< upper : lower ..< lower
    }

    /// Which band a top-down y within the half maps to, or nil outside it — above
    /// the bands (the strip's share) or past the bottom. A drop outside any band
    /// changes nothing (§22.4).
    func band(atTopDownY y: CGFloat) -> SingleFileDropTarget? {
        guard y >= topInset, y < halfHeight else { return nil }
        let inBands = y - topInset
        if inBands < stripHeight { return .insertAtStart }
        if inBands >= bandHeight - stripHeight { return .appendAtEnd }
        return .replace
    }
}

/// What dropping a dragged **pane** somewhere means
/// (`Design/PANE_DRAG_PLAN.md`).
///
/// Pure, like `DropBandLayout` and `OpenPlacement`: it knows only which pane was
/// picked up and where it was let go, so every branch is decided — and tested —
/// without a window, a pasteboard or a drag in flight. A dragging session cannot
/// be unit-tested; this is the part of it that can.
///
/// None of the outcomes is new behaviour. Each names an operation that already
/// exists with commands and tests behind it, which is the whole point: the drag
/// is a second way to reach four verbs, not a second implementation of them.
enum PaneDrop {
    /// Where the drag was let go.
    enum Destination: Equatable {
        /// Past every target — including the window's own edges.
        case outside
        /// The strip along the top of a window's content.
        case newTabStrip
        /// A pane slot: which one, whether it belongs to the window the drag
        /// started in, and which of that pane's three bands the pointer is over.
        ///
        /// Which window it is does not matter beyond same-or-other — the
        /// outcome never turns on identity. The band is the same one a dropped
        /// *file* lands in, and it means the same thing: the ends join, the
        /// middle replaces. A pane holds a dump, so joining one into another at
        /// the front or the back is the two-chip round trip (§22) with the
        /// second chip already open.
        case pane(index: Int, inOriginWindow: Bool, band: SingleFileDropTarget)
    }

    /// What the drop does.
    enum Outcome: Equatable {
        /// The pane animates back and nothing changes.
        case none
        /// The window's two panes exchange places.
        case swap
        /// The pane moves into the destination window's pane `index`.
        case move(intoPane: Int)
        /// The pane's bytes join the destination pane's, at one end or the
        /// other. A join copies — the pane it came from is left as it was, the
        /// way a joined file is left on disk.
        case join(intoPane: Int, at: JoinPosition)
        /// The pane leaves for a tab of its own.
        case tearOff
    }

    /// The meaning of letting `originIndex`'s pane go at `destination`.
    static func outcome(draggingPaneAt originIndex: Int,
                        onto destination: Destination) -> Outcome {
        switch destination {
        case .outside:
            // Deliberately not "make a new window": an accidental drop onto the
            // desktop would produce one nobody asked for, and the deliberate
            // version of that act is the strip, or Move Tab to New Window.
            return .none
        case .newTabStrip:
            return .tearOff
        case .pane(let index, let inOriginWindow, let band):
            let ontoItself = inOriginWindow && index == originIndex
            switch band {
            case .insertAtStart:
                // A pane joined to itself doubles its dump — the same operation
                // a file dropped on the pane it is already open in performs, and
                // just as real. Only the middle band is meaningless on a pane's
                // own slot.
                return .join(intoPane: index, at: .start)
            case .appendAtEnd:
                return .join(intoPane: index, at: .end)
            case .replace:
                // Trading a pane with itself is the gesture abandoned, not
                // performed. Otherwise two panes of one window trade places, and
                // a pane from elsewhere takes the slot, there being nothing to
                // trade with.
                if ontoItself { return .none }
                return inOriginWindow ? .swap : .move(intoPane: index)
            case .addSecond:
                // The free second pane of a single-file window. A pane already
                // in that window has nothing to be brought into it — it is
                // there — so only a pane from elsewhere means anything here.
                return inOriginWindow ? .none : .move(intoPane: index)
            }
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

    /// A pane being dragged by its header (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// Private on purpose. The payload is the pane's `dragID` and nothing else —
    /// not the bytes, and not a file URL, which would be a lie (a pane is not a
    /// file) and would invite every other app to accept the drag. A type nobody
    /// else declares is refused outside this process for free.
    static let pane = NSPasteboard.PasteboardType("dev.maxik.DumpCompare.pane")
}

extension NSPasteboard {
    /// The identity of the pane being dragged, when that is what this carries.
    var draggedPaneID: UUID? {
        guard let raw = string(forType: .pane) else { return nil }
        return UUID(uuidString: raw)
    }
}
