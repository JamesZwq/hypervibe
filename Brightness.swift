//
//  Brightness.swift
//  HyperVibe (config engine integration)
//
//  Display backlight control. Two mechanisms:
//   • READ current brightness via the private DisplayServices framework (dlsym'd, no linker flag) —
//     used only to tell whether we're already at minimum.
//   • SET brightness by synthesizing the hardware brightness keys (NX_KEYTYPE_BRIGHTNESS_UP/DOWN),
//     exactly like pressing F1/F2 — this moves EVERY display (including external ones that
//     DisplayServicesSetBrightness silently misses), notch by notch.
//

import Foundation
import CoreGraphics
import AppKit

enum Brightness {

    // MARK: - Read (DisplayServices)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetFn? = {
        guard let h = handle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(p, to: GetFn.self)
    }()

    /// The main display's current brightness (0...1), or nil if it can't be read.
    static func mainValue() -> Float? {
        guard let getBrightness = getBrightness else { return nil }
        var v: Float = 0
        return getBrightness(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    // MARK: - Set (synthesized brightness keys — moves ALL displays like the keyboard does)

    private static let brightnessUp:   Int32 = 2   // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown: Int32 = 3   // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let notches = 16                // full brightness range in key steps

    /// Dim every display to minimum by tapping the brightness-down key `notches` times.
    static func dimToMin()     { DispatchQueue.main.async { rampKey(brightnessDown, remaining: notches) } }
    /// Raise every display to maximum by tapping the brightness-up key `notches` times.
    static func restoreToMax() { DispatchQueue.main.async { rampKey(brightnessUp,   remaining: notches) } }

    /// If the main display is at/near minimum brightness (below `threshold`), restore ALL displays
    /// to maximum and return true; otherwise do nothing. The "only restore when at minimum" guard —
    /// a normal-brightness press never jumps to max.
    @discardableResult
    static func restoreIfDimmed(threshold: Float = 0.05) -> Bool {
        guard let value = mainValue(), value < threshold else { return false }
        restoreToMax()
        rmDebug("💡 brightness: restore → max (main was \(value))")
        return true
    }

    /// Tap the key once per notch, spaced out on the main runloop — rapid-fire system events get
    /// coalesced/dropped, and NSEvent creation must be on the main thread.
    private static func rampKey(_ keyCode: Int32, remaining: Int) {
        guard remaining > 0 else { return }
        tapAuxKey(keyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            rampKey(keyCode, remaining: remaining - 1)
        }
    }

    private static func tapAuxKey(_ keyCode: Int32) {
        postAuxKey(keyCode, down: true)
        postAuxKey(keyCode, down: false)
    }

    /// Synthesize an NX_SYSDEFINED "aux control" key event (subtype 8) — the media/brightness key
    /// path. data1 packs the key code and the up/down state.
    private static func postAuxKey(_ keyCode: Int32, down: Bool) {
        let data1 = (Int(keyCode) << 16) | ((down ? 0xa : 0xb) << 8)
        guard let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1) else { return }
        ev.cgEvent?.post(tap: .cghidEventTap)
    }
}
