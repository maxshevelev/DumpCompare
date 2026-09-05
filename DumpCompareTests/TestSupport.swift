import Cocoa
import XCTest
@testable import DumpCompare

/// Fixtures shared by the app suite, the counterpart of the core package's own
/// `TestSupport`. Everything here was, until this file existed, copied into
/// individual test classes — `tempFile` into thirty-two of them — which meant a
/// fix to one copy (deleting the file afterwards, say) reached only the class it
/// was made in.
///
/// These live on `XCTestCase` rather than in a base class the suites inherit
/// from: a base class would have to be adopted by every file at once and would
/// own `setUp`/`tearDown`, which many of these classes already use for their own
/// state. An extension is opt-in per call site and cannot break a class that
/// defines its own helper of the same name — a class's own member wins.
extension XCTestCase {
    /// A `UserDefaults` of the test class's own, emptied on the way in and
    /// **removed**, file and all, on the way out.
    ///
    /// Two things this exists for, both learned the hard way:
    ///
    /// - `removePersistentDomain(forName:)` empties a suite and leaves its
    ///   plist on disk. The test host is sandboxed into the *app's* container,
    ///   so that file lands beside the user's own preferences — and a suite
    ///   named per test left one behind per test. They reached 53 720 files and
    ///   220 MB, at which point listing the directory took minutes and the
    ///   suite's own runs were reading through all of it.
    /// - One name per class rather than per test keeps it to a single file even
    ///   if the removal ever fails again, and emptying it here gives each test
    ///   the clean slate a fresh name did.
    ///
    /// Pass `self`; the class's own name is the suite's.
    func isolatedDefaults(for owner: Any) -> (name: String, store: UserDefaults) {
        let suite = "\(type(of: owner)).isolated"
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("a suite named \(suite) is always openable")
        }
        store.removePersistentDomain(forName: suite)
        return (suite, store)
    }

    /// Empties `name`'s domain and deletes the plist `removePersistentDomain`
    /// leaves behind — see `isolatedDefaults(for:)`.
    func discardIsolatedDefaults(_ name: String, _ store: UserDefaults) {
        store.removePersistentDomain(forName: name)
        // Flush the daemon's copy first: deleting the file under a domain it is
        // still holding invites it to be written out again.
        CFPreferencesAppSynchronize(name as CFString)
        // The host is sandboxed, so `NSHomeDirectory()` is the app container's
        // Data directory; an unsandboxed run would put it in the real home.
        // Try both rather than guess which one ran.
        let homes = [NSHomeDirectory(), NSString("~").expandingTildeInPath]
        for home in homes {
            let url = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes `bytes` to a fresh file in the test host's temporary directory and
    /// deletes it when the test ends.
    ///
    /// The host is sandboxed, so this lands in the app's own container rather
    /// than `/tmp`, and a file left behind stays there for good — hence the
    /// teardown block, registered here so no caller has to remember it. Callers
    /// that must delete earlier (closing a pane before its file disappears, so
    /// the change watcher does not raise a modal) still do that themselves; a
    /// second removal of a gone file is a no-op.
    func tempFile(_ bytes: [UInt8], _ label: String = #function) throws -> URL {
        let name = label.prefix(while: { $0 != "(" })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Every view of type `T` below `view`, depth first — how a test reaches a
    /// subview that its controller does not hand out.
    func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let match = sub as? T { result.append(match) }
            result.append(contentsOf: descendants(of: sub, type))
        }
        return result
    }

    /// The first view of type `T` below `view`, or a failure naming what was
    /// missing — the shape most call sites want, since finding none is a bug in
    /// the test rather than a case to handle.
    func descendant<T: NSView>(_ type: T.Type, of view: NSView,
                               file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let found = descendants(of: view, type)
        return try XCTUnwrap(found.first, "no \(T.self) below \(Swift.type(of: view))",
                             file: file, line: line)
    }

    /// Runs the main run loop until `condition` holds or `timeout` elapses,
    /// answering whether it held. For work that finishes on the main queue with
    /// no completion hook to await — an index rebuild, a watcher's callback.
    ///
    /// Prefer a deterministic seam where the production code offers one: a test
    /// that polls is a test that is slow when it passes and slower when it
    /// fails.
    @discardableResult
    func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Polls `condition` from an async test until it holds or `timeout` elapses,
    /// yielding between checks. The counterpart of `pumpUntil` for work that
    /// lands through the main actor rather than the run loop: an async test
    /// cannot spin `RunLoop.main` to wait for a `Task` it is itself suspended
    /// in, so the two are separate helpers on purpose.
    @discardableResult
    func awaitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A synthetic mouse event in `window`'s coordinates. `clickCount` is what
    /// separates a click from a double click, so it is a parameter rather than
    /// the 1 the single-click callers want.
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow,
               clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }
}

/// A temporary favourites file, so a test never reads or writes the user's own
/// library (`Design/FAVORITES_SYNC_PLAN.md`). Paired with
/// `discardIsolatedFavoritesFile`.
func isolatedFavoritesFile(for owner: Any) -> URL {
    let name = String(describing: type(of: owner))
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DumpCompareTests-\(name)-\(UUID().uuidString)")
        .appendingPathComponent("Favorites.json")
    FavoritesFile.url = url
    return url
}

func discardIsolatedFavoritesFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    FavoritesFile.url = FavoritesFile.defaultURL()
}

/// A window a test can put views in and be sure it will not be released under
/// ARC while the test still holds it — the crash that headless AppKit tests hit
/// when a window closes itself.
@MainActor
func makeTestWindow(width: CGFloat = 800, height: CGFloat = 600) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}


/// A stand-in for the drag session AppKit hands a destination view.
///
/// The drag callbacks are where the modifier is read and the cursor is decided,
/// and until this existed no test could enter one: the views grew
/// `…ForTesting` seams that called the internals directly, which is exactly the
/// path a bug in `draggingEntered`/`draggingUpdated` itself walks past. Only the
/// four members our destinations touch carry anything; the rest of
/// `NSDraggingInfo` is stubbed because a destination that reached for them would
/// be doing something this app does not do.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    var draggingSourceOperationMask: NSDragOperation
    var draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard

    /// A session carrying `paneID`, with the mask AppKit narrows to `.copy` when
    /// Option is held and leaves as `[.move, .copy]` when it is not.
    init(paneID: UUID, copying: Bool, at location: NSPoint = .zero) {
        let board = NSPasteboard(name: NSPasteboard.Name("FakeDrag-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(paneID.uuidString, forType: .pane)
        draggingPasteboard = board
        draggingSourceOperationMask = copying ? .copy : [.move, .copy]
        draggingLocation = location
    }

    /// Option pressed or released mid-drag: AppKit re-narrows the mask and sends
    /// another update, which is the whole shape of the bug this exists for.
    func setCopying(_ copying: Bool) {
        draggingSourceOperationMask = copying ? .copy : [.move, .copy]
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
