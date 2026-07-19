//
//  SettingsModel.swift
//  HyperVibe (settings UI)
//

import Foundation
import Combine

/// Observable wrapper around TuneSettings. Any change persists and applies live.
final class SettingsModel: ObservableObject {
    @Published var tune: TuneSettings {
        didSet {
            guard tune != oldValue else { return }
            TuneStore.save(tune)
            onApply?(tune)
        }
    }

    /// Live connection status shown in the window header.
    @Published var connected: Bool = false

    /// The live parsed config (modes / bindings / appProfiles), refreshed on hot-reload.
    /// Read-only for the "Layout" tab. Set by AppDelegate at load and on every config reload.
    @Published var config: Config?

    /// Set by AppDelegate to push values into the running TouchHandler.
    var onApply: ((TuneSettings) -> Void)?

    init(initial: TuneSettings) {
        self.tune = initial
    }

    func resetToDefaults() {
        tune = .default
    }
}
