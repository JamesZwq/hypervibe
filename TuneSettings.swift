//
//  TuneSettings.swift
//  HyperVibe (settings UI)
//
//  UI-managed tuning values (cursor + circular scroll). Persisted in UserDefaults so the
//  Settings window is the source of truth; seeded once from the config file's settings.
//

import Foundation

struct TuneSettings: Codable, Equatable {
    var cursorSpeed: Double
    var cursorDeadzone: Double
    var circularEnabled: Bool
    var circularMinRadius: Double
    var circularStartThreshold: Double
    var circularPixelsPerRadian: Double
    var circularInvert: Bool

    static let `default` = TuneSettings(
        cursorSpeed: 0.6, cursorDeadzone: 0.006,
        circularEnabled: true, circularMinRadius: 0.35, circularStartThreshold: 0.35,
        circularPixelsPerRadian: 160, circularInvert: false)

    /// Seed from the config file's settings block (used on first run only).
    init(seed s: Config.Settings) {
        cursorSpeed = s.cursorSpeed
        cursorDeadzone = s.cursorDeadzone
        circularEnabled = s.circularScroll.enabled
        circularMinRadius = s.circularScroll.minRadius
        circularStartThreshold = s.circularScroll.startThreshold
        circularPixelsPerRadian = s.circularScroll.pixelsPerRadian
        circularInvert = s.circularScroll.invert
    }

    init(cursorSpeed: Double, cursorDeadzone: Double, circularEnabled: Bool,
         circularMinRadius: Double, circularStartThreshold: Double,
         circularPixelsPerRadian: Double, circularInvert: Bool) {
        self.cursorSpeed = cursorSpeed
        self.cursorDeadzone = cursorDeadzone
        self.circularEnabled = circularEnabled
        self.circularMinRadius = circularMinRadius
        self.circularStartThreshold = circularStartThreshold
        self.circularPixelsPerRadian = circularPixelsPerRadian
        self.circularInvert = circularInvert
    }

    /// The SiriRemoteCore circular-scroll config this maps to.
    var circularConfig: CircularScrollConfig {
        CircularScrollConfig(
            enabled: circularEnabled,
            minRadius: circularMinRadius,
            startThreshold: circularStartThreshold,
            pixelsPerRadian: circularPixelsPerRadian,
            invert: circularInvert)
    }
}

enum TuneStore {
    private static let key = "siriRemote.tune.v1"

    static func load() -> TuneSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TuneSettings.self, from: data)
    }

    static func save(_ t: TuneSettings) {
        if let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
