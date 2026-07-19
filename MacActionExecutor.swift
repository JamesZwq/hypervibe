//
//  MacActionExecutor.swift
//  HyperVibe (config engine integration)
//
//  Bridges SiriRemoteCore `Action`s to real macOS effects (CGEvent, media keys,
//  app launch, shell, AppleScript). `Action`, `EventPayload`, `ActionExecutor`
//  come from SiriRemoteCore, compiled into this target by build.sh.
//

import Foundation
import AppKit
import CoreGraphics

final class MacActionExecutor: ActionExecutor {
    private let media = MediaController()

    func execute(_ action: Action, payload: EventPayload?) {
        switch action {
        case .keystroke(let keys):
            Keys.synthesize(keys)
        case .media(let key):
            postMedia(key)
        case .mouse(let op):
            Mouse.perform(op, payload: payload)
        case .launch(let app, let url):
            if let app = app { Shell.run("open -a \(shellQuote(app))") }
            if let url = url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .shell(let command):
            Shell.run(command)
        case .applescript(let script):
            AppleScriptRunner.run(script)
        case .mode:
            break // handled inside Controller; never reaches the executor
        }
    }

    private func postMedia(_ key: String) {
        let type: MediaKeyInterceptor.MediaKeyType
        switch key {
        case "playpause":            type = .playPause
        case "next":                 type = .next
        case "previous":             type = .previous
        case "volup", "volumeup":    type = .volumeUp
        case "voldown", "volumedown":type = .volumeDown
        case "mute":                 type = .mute
        default:
            NSLog("[siriRemote] unknown media key '\(key)'"); return
        }
        media.sendMediaKey(type)
    }
}

// MARK: - Effect helpers (self-contained CGEvent / Process wrappers)

enum Keys {
    static func synthesize(_ combo: String) {
        guard let (code, flags) = KeyMap.parse(combo) else {
            NSLog("[siriRemote] unknown keystroke '\(combo)'"); return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum Mouse {
    static func perform(_ op: String, payload: EventPayload?) {
        switch op {
        case "click":      click(.left)
        case "rightclick": click(.right)
        case "move":
            guard case let .delta(dx, dy)? = payload else { return }
            let cur = NSEvent.mouseLocation
            let to = CGPoint(x: cur.x + dx, y: cur.y - dy) // AppKit y-up → CG y-down
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
        case "scroll":
            guard case let .delta(dx, dy)? = payload else { return }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
        default:
            NSLog("[siriRemote] unknown mouse op '\(op)'")
        }
    }

    private static func click(_ button: CGMouseButton) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType   = button == .left ? .leftMouseUp   : .rightMouseUp
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pos, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pos, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }
}

/// Single-quote a string for safe interpolation into a /bin/zsh -c command.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum Shell {
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        do { try p.run() } catch { NSLog("[siriRemote] shell failed: \(error)") }
    }
}

enum AppleScriptRunner {
    static func run(_ source: String) {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err { NSLog("[siriRemote] applescript failed: \(err)") }
    }
}
