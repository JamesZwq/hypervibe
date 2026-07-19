//
//  Brightness.swift
//  HyperVibe (config engine integration)
//
//  Control display backlight brightness via the private DisplayServices framework, loaded with
//  dlsym (no linker flag needed) — mirrors how Spaces.swift dlopens SkyLight. Used so the Power
//  button can dim ALL displays to minimum (the Mac stays awake / remote-controllable, unlike
//  display sleep) and any subsequent button/touch restores them to maximum. Private API —
//  experimental and macOS-version dependent; robust to the symbols being unavailable.
//

import Foundation
import CoreGraphics

enum Brightness {
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let setBrightness: SetFn? = fn("DisplayServicesSetBrightness", SetFn.self)
    private static let getBrightness: GetFn? = fn("DisplayServicesGetBrightness", GetFn.self)

    /// All currently active (drawable) displays. Queries the count first, then fills the list.
    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Set every active display's brightness to `value` (clamped 0...1). No-op if the symbol is
    /// unavailable.
    static func setAll(_ value: Float) {
        guard let setBrightness = setBrightness else {
            rmDebug("💡 brightness: DisplayServicesSetBrightness unavailable"); return
        }
        let clamped = min(max(value, 0), 1)
        let displays = activeDisplays()
        for id in displays { _ = setBrightness(id, clamped) }
        rmDebug("💡 brightness: set \(displays.count) display(s) → \(clamped)")
    }

    /// The main display's current brightness (0...1), or nil if it can't be read.
    static func mainValue() -> Float? {
        guard let getBrightness = getBrightness else { return nil }
        var v: Float = 0
        return getBrightness(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    /// If the main display is currently at/near minimum brightness (below `threshold`), restore ALL
    /// displays to maximum and return true; otherwise do nothing and return false. This is the
    /// "only restore when at minimum" guard — a normal-brightness press never jumps to max.
    @discardableResult
    static func restoreIfDimmed(threshold: Float = 0.05) -> Bool {
        guard let value = mainValue(), value < threshold else { return false }
        setAll(1.0)
        rmDebug("💡 brightness: restored to max (was \(value))")
        return true
    }
}
