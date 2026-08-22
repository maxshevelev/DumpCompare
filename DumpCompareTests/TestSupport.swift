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
