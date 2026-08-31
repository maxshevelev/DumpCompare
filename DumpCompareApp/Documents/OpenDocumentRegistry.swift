import Foundation
import DumpCompareCore

/// Which window has a given file open (§4.1 rule 6).
///
/// The rule — the same file may not be open twice — used to be one window's own
/// business, answered by looking at its other pane. It is not fussiness: two
/// live documents over one file are two dirty states, two change watchers, and
/// a piece table whose base file moves under it the moment the other document
/// saves. That is the family of corruption `StorageSaver` now refuses outright.
///
/// Once there can be more than one window the question stops being a window's
/// and becomes the application's, so it is asked here instead.
///
/// **Nothing is stored about the files.** The answer is computed from the panes
/// themselves at the moment it is asked, so it cannot fall out of step with what
/// is actually open — which the two-pane check never could either. The only
/// state is the list of live controllers, and it is held weakly: a window that
/// goes away drops out on its own, and a stale entry can only ever be an empty
/// one.
@MainActor
final class OpenDocumentRegistry {
    private struct Entry {
        weak var controller: MainViewController?
    }

    private var entries: [Entry] = []

    /// Adds a window's controller. Registering one twice is a no-op, so a caller
    /// need not track whether it has already done so.
    func register(_ controller: MainViewController) {
        compact()
        guard !entries.contains(where: { $0.controller === controller }) else { return }
        entries.append(Entry(controller: controller))
    }

    /// The window and pane holding the file at `url`, or nil when nothing does.
    /// `excluding` names the pane the caller is about to open into — the target
    /// of an open is never its own obstacle, and a file already in that very
    /// pane is a reload (§4.1 rule 5), not a refusal.
    func location(of url: URL,
                  excluding: (controller: MainViewController, paneIndex: Int)?)
    -> (controller: MainViewController, paneIndex: Int)? {
        compact()
        let identity = FileIdentity(url: url)
        for entry in entries {
            guard let controller = entry.controller else { continue }
            let skip = excluding?.controller === controller ? excluding?.paneIndex : nil
            if let paneIndex = controller.paneIndex(holding: identity, excluding: skip) {
                return (controller, paneIndex)
            }
        }
        return nil
    }

    /// The window and pane index of the pane carrying `dragID`, or nil when no
    /// window has it any more — which is the answer when the pane was closed, or
    /// its window shut, while a drag of it was in flight.
    ///
    /// Nothing is stored here either: the panes are asked at the moment of the
    /// question, so a stale drag resolves to nothing by construction rather than
    /// by a check somebody has to remember to write.
    func location(ofPaneWith dragID: UUID)
    -> (controller: MainViewController, paneIndex: Int)? {
        compact()
        for entry in entries {
            guard let controller = entry.controller else { continue }
            if let paneIndex = controller.paneIndex(withDragID: dragID) {
                return (controller, paneIndex)
            }
        }
        return nil
    }

    /// Every window still open. Used where something is the whole app's
    /// business rather than one window's — a pane drag, which any window can
    /// receive.
    var controllers: [MainViewController] {
        compact()
        return entries.compactMap(\.controller)
    }

    private func compact() {
        entries.removeAll { $0.controller == nil }
    }
}
