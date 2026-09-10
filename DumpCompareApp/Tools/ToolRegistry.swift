import FITToolUI
import Foundation
import MEAToolUI
import ToolModuleKit
import UEFIToolUI
#if DEBUG
import ZoneSketchUI
#endif

/// Every tool-module the app ships, in the order the Tools menu lists them
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// A list rather than a discovery mechanism: tool-modules are packages in this
/// repository, linked into the app, so what is installed is known when the app
/// is built. Nothing here loads a bundle, and nothing decides whether a
/// tool-module *applies* to the open file — the host offers all of them for
/// every file, and "there is no FIT table in this image" is a sentence the
/// tool-module says in its own panel rather than a grey menu item that explains
/// nothing.
enum ToolRegistry {
    /// The tool-modules a shipping build offers, in the order the menu lists
    /// them. One line per module; the package it comes from is a line in
    /// `project.yml`.
    static let shipping: [any ToolModule.Type] =
        [MEAToolModule.self, FITToolModule.self, UEFIToolModule.self]

    /// What this build offers: the shipping ones, and — in a debug build only —
    /// Zone Sketch.
    ///
    /// Zone Sketch is a demonstration: it draws zones to show what the seam can
    /// do, and answers no question about a dump. That is worth having while the
    /// seam is being worked on and worth nothing to a bench, so a release build
    /// does not offer it — the menu does not list it and its identifier
    /// resolves to nothing, which is the same as a module removed between
    /// builds.
    ///
    /// Its code is still linked there. The app target depends on the package in
    /// `project.yml`, an Xcode target's dependencies cannot be made
    /// configuration-specific, and the conformance records keep the linker from
    /// stripping what nothing references (measured: 66 `ZoneSketch` symbols in
    /// a release binary). Keeping it out of the binary as well would mean the
    /// app not linking the package at all — and then a debug *run* would not
    /// have the panel either, only the tests that register it themselves. The
    /// panel is for using while developing, so it stays linked and unoffered.
    static let builtIn: [any ToolModule.Type] = {
        #if DEBUG
        return shipping + [ZoneSketchModule.self]
        #else
        return shipping
        #endif
    }()

    /// What the menu is built from. A `var` so a test can install its own
    /// stand-ins without a real tool-module existing, the way the minimap's
    /// defaults store is swapped — and restore them afterwards.
    static var modules: [any ToolModule.Type] = builtIn

    /// The tool-module a menu item, or a remembered choice, names. Nil for an
    /// identifier nothing answers to, which is what a module removed between
    /// builds looks like.
    static func module(identified identifier: String) -> (any ToolModule.Type)? {
        modules.first { $0.identifier == identifier }
    }
}
