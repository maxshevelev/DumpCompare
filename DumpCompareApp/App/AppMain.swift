import Cocoa

/// Programmatic AppKit entry point (no storyboard or nib).
@main
enum DumpCompareMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
