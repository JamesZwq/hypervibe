//
//  LayerHUD.swift
//  HyperVibe
//
//  A macOS-style heads-up overlay (like the system volume / brightness HUD) shown briefly when a
//  sticky LAYER is toggled on or off, so there's clear on-screen confirmation of the switch. A
//  borderless, click-through window with the vibrant `.hudWindow` material, a large SF Symbol, and
//  the layer's name; fades in, holds, fades out. Only fires for the sticky toggle (not the
//  transient momentary hold, which would flash). All UI runs on main.
//

import AppKit
import QuartzCore

final class LayerHUD {

    private let side: CGFloat = 176
    private var window: NSWindow?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?

    /// How long the HUD stays before fading out (each show resets it).
    private let holdDuration: TimeInterval = 0.9
    private var hideTimer: Timer?
    private var fadeToken = 0
    private var isShowing = false

    init() {}

    // MARK: - Public API

    /// A layer turned ON (sticky): accent tint, filled-layers icon.
    func showOn(_ layerName: String) {
        show(symbol: "square.stack.3d.up.fill", title: layerName, subtitle: "Layer on",
             tint: .controlAccentColor)
    }

    /// A layer turned OFF (back to base): dimmed tint, slashed-layers icon.
    func showOff(_ layerName: String) {
        show(symbol: "square.stack.3d.up.slash.fill", title: layerName, subtitle: "Layer off",
             tint: .secondaryLabelColor)
    }

    // MARK: - Show / hide

    private func show(symbol: String, title: String, subtitle: String, tint: NSColor) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            self.configure(symbol: symbol, title: title, subtitle: subtitle, tint: tint)
            self.fadeToken += 1
            self.positionWindow()
            if !self.isShowing {
                self.isShowing = true
                self.window?.alphaValue = 0
                self.window?.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    self.window?.animator().alphaValue = 1
                }
            } else {
                self.window?.animator().alphaValue = 1
            }
            self.resetHideTimer()
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.beginHide()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func beginHide() {
        guard isShowing else { return }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.fadeToken == token else { return }
            self.isShowing = false
            self.window?.orderOut(nil)
        })
    }

    // MARK: - Content

    private func configure(symbol: String, title: String, subtitle: String, tint: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 66, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        iconView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        // Show the layer's own name prominently, with an on/off subtitle beneath.
        titleLabel?.stringValue = title.isEmpty ? subtitle : title
        subtitleLabel?.stringValue = title.isEmpty ? "" : subtitle
    }

    // MARK: - Window

    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        // Horizontal center, lower third — where the system volume/brightness HUD sits.
        let x = vf.midX - side / 2
        let y = vf.minY + vf.height * 0.18
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Vibrant HUD panel with rounded corners (the classic macOS overlay look).
        let vev = NSVisualEffectView(frame: rect)
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 24
        vev.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 0, y: side * 0.36, width: side, height: side * 0.42))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        vev.addSubview(icon)

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 8, y: side * 0.185, width: side - 16, height: 24)
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        vev.addSubview(label)

        let sub = NSTextField(labelWithString: "")
        sub.frame = NSRect(x: 8, y: side * 0.085, width: side - 16, height: 18)
        sub.alignment = .center
        sub.font = .systemFont(ofSize: 11.5, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        vev.addSubview(sub)

        win.contentView = vev
        window = win
        iconView = icon
        titleLabel = label
        subtitleLabel = sub
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
