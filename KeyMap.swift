//
//  KeyMap.swift
//  HyperVibe (config engine integration)
//
//  Parses keystroke strings like "cmd+shift+up" into a virtual key code + modifier flags.
//

import Carbon.HIToolbox
import CoreGraphics

enum KeyMap {
    /// Parse "cmd+shift+up" → (keyCode, flags). Returns nil on any unknown token.
    static func parse(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let tokens = combo.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyToken = tokens.last else { return nil }

        var flags: CGEventFlags = []
        for mod in tokens.dropLast() {
            switch mod {
            case "cmd", "command":     flags.insert(.maskCommand)
            case "shift":              flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control":    flags.insert(.maskControl)
            default: return nil
            }
        }
        guard let code = keyCode(for: keyToken) else { return nil }
        return (CGKeyCode(code), flags)
    }

    private static func keyCode(for token: String) -> Int? {
        if token.count == 1, let ch = token.first {
            if let c = letters[ch] { return c }
            if let d = digits[ch] { return d }
        }
        return named[token]
    }

    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]

    private static let digits: [Character: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    private static let named: [String: Int] = [
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "esc": kVK_Escape, "escape": kVK_Escape,
        "enter": kVK_Return, "return": kVK_Return,
        "space": kVK_Space, "tab": kVK_Tab,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    ]
}
