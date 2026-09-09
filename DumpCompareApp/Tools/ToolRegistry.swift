import FITToolUI
import Foundation
import MEAToolUI
import ToolModuleKit
import UEFIToolUI
import ZoneSketchUI

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
    /// The tool-modules of the shipping app, in the order the menu lists them.
    /// One line per module; the package it comes from is a line in
    /// `project.yml`.
    static let builtIn: [any ToolModule.Type] = [MEAToolModule.self, FITToolModule.self, UEFIToolModule.self, ZoneSketchModule.self]

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
