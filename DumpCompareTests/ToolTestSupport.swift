import Cocoa
import XCTest
import ToolModuleKit
@testable import DumpCompare

/// Stand-ins for tool-modules, so the host's half can be tested before a real
/// one exists — and afterwards, without dragging a parser into a test about a
/// menu or a panel (`Design/TOOL_MODULES_PLAN.md`).
///
/// A `ToolModule` is a type rather than an instance, so a configurable stub is
/// not possible: what varies is spelled out as two concrete stubs. Each records
/// what its sessions did in a static box, cleared by `resetToolStubs()`.

/// What a stub session did, so a test can look afterwards.
final class ToolStubLog {
    var started = 0
    var stopped = 0
    var changes: [ToolContentChange] = []
    /// The notes of the states handed back to this stub's sessions, in order.
    var restored: [String] = []
    /// The last session the stub built, for a test that wants to drive it.
    weak var session: StubToolSession?

    func reset() {
        started = 0
        stopped = 0
        changes = []
        restored = []
        session = nil
    }
}

/// A stub's parked state: one note, so a test can tell whose it was.
struct StubToolState: ToolSessionState, Equatable {
    var note: String
}

@MainActor final class StubToolSession: ToolSession {
    let host: any ToolHost
    let log: ToolStubLog
    let viewController: NSViewController

    /// Published by `start()`, so a test can watch a map reach the dump without
    /// a parser. Nil publishes nothing.
    var mapOnStart: ZoneMap?

    init(host: any ToolHost, log: ToolStubLog, label: String) {
        self.host = host
        self.log = log
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.view.identifier = NSUserInterfaceItemIdentifier(label)
        self.viewController = controller
        log.session = self
    }

    func start() {
        log.started += 1
        if let mapOnStart { host.publish(mapOnStart) }
    }

    func contentChanged(_ change: ToolContentChange) { log.changes.append(change) }
    func stop() { log.stopped += 1 }

    /// What this session will hand back when it ends. Nil — the default for a
    /// tool-module that keeps nothing — until a test sets it.
    var stateToPark: (any ToolSessionState)?

    var parkedState: (any ToolSessionState)? { stateToPark }

    func restore(_ state: any ToolSessionState) {
        guard let state = state as? StubToolState else { return }
        log.restored.append(state.note)
    }
}

enum StubToolA: ToolModule {
    static let identifier = "dev.maxik.tool.stubA"
    static let title = "Stub A"
    static let preferredPanelWidth: CGFloat = 300
    static let log = ToolStubLog()

    @MainActor static func makeSession(host: any ToolHost) -> any ToolSession {
        StubToolSession(host: host, log: log, label: "StubA")
    }
}

enum StubToolB: ToolModule {
    static let identifier = "dev.maxik.tool.stubB"
    static let title = "Stub B"
    static let preferredPanelWidth: CGFloat = 500
    static let log = ToolStubLog()

    @MainActor static func makeSession(host: any ToolHost) -> any ToolSession {
        StubToolSession(host: host, log: log, label: "StubB")
    }
}

@MainActor extension XCTestCase {
    /// Installs the stubs as the whole of what is installed, and puts the real
    /// list back when the test ends.
    func installToolStubs(_ modules: [any ToolModule.Type] = [StubToolA.self, StubToolB.self]) {
        let restored = ToolRegistry.modules
        ToolRegistry.modules = modules
        StubToolA.log.reset()
        StubToolB.log.reset()
        addTeardownBlock {
            ToolRegistry.modules = restored
            StubToolA.log.reset()
            StubToolB.log.reset()
        }
    }
}
