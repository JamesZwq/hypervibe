//
//  ConfigStore.swift
//  HyperVibe (config engine integration)
//
//  Loads the user config from ~/.config/siriremote/config.jsonc, bootstrapping a
//  commented default on first run. Uses an embedded default string (not a bundled
//  resource) so it works whether launched as a bare binary or an .app.
//

import Foundation

enum ConfigStore {
    static var path: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/siriremote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.jsonc")
    }

    /// Read the config file, writing the default template on first run.
    static func loadOrBootstrapText() -> String {
        if let text = try? String(contentsOf: path, encoding: .utf8) { return text }
        try? defaultTemplate.write(to: path, atomically: true, encoding: .utf8)
        return defaultTemplate
    }

    /// Parse the on-disk config; falls back to a minimal valid config if it is broken,
    /// so the app never ends up with no engine at all.
    static func loadConfig() -> Config {
        if let cfg = try? ConfigLoader.load(loadOrBootstrapText()) { return cfg }
        NSLog("[siriRemote] config invalid — using empty fallback")
        return (try? ConfigLoader.load(minimalFallback))!
    }

    static let minimalFallback =
        "{ \"settings\": { \"defaultMode\": \"global\" }, \"modes\": { \"global\": {} } }"

    /// Shipped default. Bindings here OVERRIDE HyperVibe's native button behavior;
    /// anything left unbound falls through to native (push-to-talk, click/drag, etc.).
    /// Empty by default so nothing native is clobbered until you opt in.
    static let defaultTemplate = """
    {
      // siriRemote config — edit and save; changes hot-reload live.
      // Event keys: ring.up ring.down ring.left ring.right
      //             swipe.up swipe.down swipe.left swipe.right tap.two
      //             button.menu button.tv button.siri button.playPause
      //             button.volumeUp button.volumeDown button.back
      //             button.nextTrack button.prevTrack button.mute button.power
      // Actions: keystroke(keys) media(key) mouse(op) launch(app|url)
      //          shell(command) applescript(script) mode(to)
      // A binding OVERRIDES native behavior; unbound buttons stay native.
      "settings": {
        "defaultMode": "global",
        "cursorSpeed": 0.6,       // lower = slower / less sensitive
        "cursorDeadzone": 0.006,  // higher = more jitter ignored, easier to hold & click
        // Circular scroll (iPod wheel): circle a finger on the OUTER ring to scroll.
        "circularScroll": {
          "enabled": true,
          "minRadius": 0.35,       // only touches this far from center count (outer ring)
          "startThreshold": 0.35,  // radians to rotate before scrolling starts
          "pixelsPerRadian": 160,  // scroll pixels per radian of rotation (speed)
          "invert": false          // flip if it scrolls the wrong way
        }
      },

      // Per-app auto-switch: frontmost app's bundle id -> mode name.
      "appProfiles": {
        // "com.microsoft.VSCode": "vscode",
        // "com.apple.iWork.Keynote": "keynote",
        "default": "global"
      },

      "modes": {
        "global": {
          // Click-ring → arrow keys (works out of the box):
          "ring.up":    { "action": "keystroke", "keys": "up" },
          "ring.down":  { "action": "keystroke", "keys": "down" },
          "ring.left":  { "action": "keystroke", "keys": "left" },
          "ring.right": { "action": "keystroke", "keys": "right" }
          // To add more, put a comma after the line above, then e.g.:
          // ,"button.tv":   { "action": "shell", "command": "open -a Safari" }
          // ,"swipe.left":  { "action": "keystroke", "keys": "cmd+[" }
          // ,"swipe.right": { "action": "keystroke", "keys": "cmd+]" }
        }
        // ,"keynote": { "inherits": "global",
        //   "ring.right": { "action": "keystroke", "keys": "right" },
        //   "ring.left":  { "action": "keystroke", "keys": "left" } }
      }
    }
    """
}
