//
//  SettingsWindow.swift
//  HyperVibe (settings UI)
//
//  Hosts the SwiftUI SettingsView in a clean, borderless-title window from the menu-bar app.
//

import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            // Track the SwiftUI content's fitting size so the window grows/shrinks when the
            // Layout tab (wider) is selected vs. the Tuning tab.
            hosting.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: hosting)
            win.title = "siriRemote Settings"
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
