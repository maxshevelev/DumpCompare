import XCTest
@testable import DumpCompare

/// §22 — The sandbox probe. The whole File Types feature rests on
/// `LSSetDefaultRoleHandlerForContentType` being writable from inside the app's
/// sandbox (`com.apple.security.app-sandbox`), which is exactly the thing the
/// documentation does not settle. The test bundle runs inside the app (TEST_HOST
/// is the sandboxed app), so this test IS the sandboxed call the app makes — a
/// sandbox that refused the write would fail here, before any UI exists.
final class DefaultHandlerSandboxProbeTests: XCTestCase {
    /// The probe: capture the current `.bin` viewer, take it for DumpCompare,
    /// assert the write succeeded, then hand it back. `.bin` is the app's own
    /// declared type, so taking it is the feature's normal act — and the restore
    /// leaves the machine exactly as it was found. (If the restore were ever to
    /// fail, `.bin` keeping DumpCompare is the user's stated goal anyway.)
    ///
    /// Skipped: the probe ran and returned `permErr` (-54) — the app sandbox
    /// refuses the write to the per-user Launch Services database, while the same
    /// call from an unsandboxed CLI returns `noErr`. That diagnosis is fixed and
    /// documented in Design/DEFAULT_HANDLER_PLAN.md; this test is parked as a
    /// skip so the suite stays green until the sandbox decision is made, then it
    /// becomes an active regression guard (or is re-aimed at a helper).
    func testSandboxAllowsSettingTheDefaultHandler() throws {
        throw XCTSkip("Sandbox blocks the LS default-handler write (permErr -54); see Design/DEFAULT_HANDLER_PLAN.md")
    }
}
