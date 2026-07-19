//
//  RemoteInputHandler.swift
//  HyperVibe
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []

    /// Config engine (SiriRemoteCore). Buttons are routed through it; unbound buttons do nothing.
    var controller: Controller?

    /// Long-press: if a `<key>.hold` binding exists, hold past this many seconds fires it; a
    /// short press fires the plain `<key>` on release. HID callbacks run on the main runloop.
    var holdThreshold: TimeInterval = 0.5
    private var pendingHold: [String: DispatchWorkItem] = [:]
    private var holdFired: Set<String> = []

    /// Double-tap: if a `<key>.double` binding exists, the single is HELD for `doubleTapWindow` to
    /// see whether a 2nd tap arrives. A lone tap fires `<key>` only after the window elapses; a
    /// quick 2nd tap cancels that pending single and fires `<key>.double` instead — so a double-tap
    /// emits ONLY the double, never a single too. Keys with no `.double` binding fire the single
    /// immediately (zero added latency).
    var doubleTapWindow: TimeInterval = 0.3
    private var pendingSingle: [String: DispatchWorkItem] = [:]

    /// Hold-to-repeat: a `.repeatKey` binding auto-repeats its keystroke while the button is held
    /// (HID sends a press then a release with NO auto-repeat, so the app generates the repeats).
    /// A press fires once + schedules a repeating timer (after `delay`, every `interval`); the
    /// matching release stops it. Keyed by HID button name. Bypasses `.hold`/`.double` entirely.
    private var repeatTimers: [String: DispatchSourceTimer] = [:]

    /// Spaces Mode: long-pressing ring.up opens Mission Control AND arms this mode. While armed,
    /// ring.left/right switch desktops (animated, via BetterTouchTool) and each switch restarts a
    /// `spacesModeWindow` timer. It exits (disarms) on ring.down (also closes Mission Control), a
    /// second ring.up long-press (also closes Mission Control), or `spacesModeWindow` of inactivity.
    var spacesModeWindow: TimeInterval = 5.0
    private var spacesModeActive = false
    private var spacesModeTimer: DispatchWorkItem?

    /// BetterTouchTool predefined-action triggers for animated space switching (HANDOFF §6):
    /// action 113 = move one space left, 114 = move one space right. Run via the shell (`open -g`).
    private static let bttSpaceLeftCommand  = "open -g \"btt://trigger_action/?json=%7B%22BTTPredefinedActionType%22%3A113%7D\""
    private static let bttSpaceRightCommand = "open -g \"btt://trigger_action/?json=%7B%22BTTPredefinedActionType%22%3A114%7D\""

    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private let clickThreshold: Double = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// Captured at press time so release can fire the correct keyUp even if the user
    /// rebinds the button mid-hold. Cleared on device removal to avoid stuck modifiers.
    private var heldKeys: [String: (keyCode: Int, flags: CGEventFlags)] = [:]

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            releaseAllHeldKeys()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            isFirstPressAfterConnection = true
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                isFirstPressAfterConnection = true
            }
        }
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = (intValue == 1)
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed

        // Volume keys are left to the remote's native BT/AVRCP absolute-volume path so they
        // control system volume in every app (we no longer arm the revert guard to undo it).

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        // Config-driven only, with long-press discrimination.
        routeButton(buttonName, pressed: pressed)
    }

    /// Route a button press/release through the config engine. If a `<key>.hold` binding exists,
    /// holding past `holdThreshold` fires `<key>.hold` and a short press fires `<key>` on release;
    /// otherwise the tap fires immediately on press. Unbound events do nothing.
    private func routeButton(_ buttonName: String, pressed: Bool) {
        guard let controller = controller else { return }
        let tapKey = RemoteInputHandler.configKey(for: buttonName)
        let holdKey = tapKey + ".hold"

        // 1) Spaces Mode: while armed, the ring becomes a desktop switcher. Intercept on press,
        //    BEFORE any config dispatch, and consume so the normal binding doesn't also fire.
        //    (ring.up long-press is handled in the hold path below so a hold can toggle it off.)
        if spacesModeActive && pressed {
            switch tapKey {
            case "ring.left":
                Shell.run(RemoteInputHandler.bttSpaceLeftCommand)
                restartSpacesModeTimer()
                print("🖥 Spaces Mode: ← space")
                return
            case "ring.right":
                Shell.run(RemoteInputHandler.bttSpaceRightCommand)
                restartSpacesModeTimer()
                print("🖥 Spaces Mode: → space")
                return
            case "ring.down":
                sendKey(kVK_Escape)          // close Mission Control
                disarmSpacesMode()
                print("🖥 Spaces Mode: exit (ring.down)")
                return
            default:
                break                        // other buttons pass through normally, no disarm
            }
        }

        // 2) Hold-to-repeat: if this key resolves to a `.repeatKey` action, bypass the normal
        //    hold/double discrimination — a press fires once and starts an auto-repeat, and the
        //    release stops it. (Because this bypasses the `.hold` path, an inherited `<key>.hold`
        //    binding is intentionally NOT reachable for a `.repeatKey` key.)
        if case let .repeatKey(keys, delay, interval)? = controller.resolvedAction(for: tapKey) {
            if pressed {
                startKeyRepeat(buttonName, tapKey: tapKey, keys: keys, delay: delay, interval: interval)
            } else {
                stopKeyRepeat(buttonName)
            }
            return
        }

        if pressed {
            guard controller.hasBinding(for: holdKey) else {
                // No long-press binding → the tap completes on press. Fire the single immediately
                // (no added latency), or a `.double` if this is a quick 2nd tap.
                fireTapOrDouble(buttonName, tapKey: tapKey)
                return
            }
            // Long-press exists → decide short vs long: fire hold at the threshold, tap on early release.
            holdFired.remove(buttonName)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingHold[buttonName] = nil
                self.holdFired.insert(buttonName)
                self.fireHold(controller: controller, holdKey: holdKey)
            }
            pendingHold[buttonName] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
        } else {
            // Release: if a pending hold hasn't fired yet, it was a short press → the tap completes
            // here. Fire the single (or a `.double` if this is a quick 2nd tap).
            if let work = pendingHold.removeValue(forKey: buttonName) {
                work.cancel()
                if !holdFired.contains(buttonName) {
                    fireTapOrDouble(buttonName, tapKey: tapKey)
                }
            }
            holdFired.remove(buttonName)
        }
    }

    /// Run a long-press (`<key>.hold`) action. `ring.up.hold` additionally toggles Spaces Mode:
    /// the first long-press runs its config action (open Mission Control) and arms; a second
    /// long-press while armed closes Mission Control (Escape) and disarms instead of re-opening.
    private func fireHold(controller: Controller, holdKey: String) {
        if holdKey == "ring.up.hold" {
            if spacesModeActive {
                sendKey(kVK_Escape)              // close Mission Control
                disarmSpacesMode()
                print("🖥 Spaces Mode: exit (ring.up long-press)")
                return
            }
            if controller.handle(InputEvent(key: holdKey)) { print("🔘 \(holdKey) (config)") }
            armSpacesMode()                      // Mission Control now open → arm desktop switching
            return
        }
        if controller.handle(InputEvent(key: holdKey)) { print("🔘 \(holdKey) (config)") }
    }

    // MARK: - Hold-to-repeat (Feature 1)

    /// Start auto-repeating `keys` for `buttonName`. Fires once immediately (through the config
    /// path so it's logged like any dispatch), then after `delay` repeats every `interval` on the
    /// main queue until `stopKeyRepeat`. Repeats call `Keys.synthesize` directly to avoid
    /// re-resolving the binding every tick.
    private func startKeyRepeat(_ buttonName: String, tapKey: String, keys: String,
                                delay: Double, interval: Double) {
        stopKeyRepeat(buttonName)   // defensive: never stack two repeats on one button

        // First fire via the controller so it logs and honors the config path (executor
        // synthesizes a single keystroke for `.repeatKey`).
        if controller?.handle(InputEvent(key: tapKey)) == true { print("🔘 \(tapKey) ⟳ (config)") }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: interval)
        timer.setEventHandler { Keys.synthesize(keys) }
        repeatTimers[buttonName] = timer
        timer.resume()
    }

    /// Stop and clear the auto-repeat timer for `buttonName` (on release, a new press, or teardown).
    private func stopKeyRepeat(_ buttonName: String) {
        if let timer = repeatTimers.removeValue(forKey: buttonName) { timer.cancel() }
    }

    private func stopAllKeyRepeats() {
        for (_, timer) in repeatTimers { timer.cancel() }
        repeatTimers.removeAll()
    }

    // MARK: - Spaces Mode (Feature 2)

    /// Arm Spaces Mode (called right after ring.up.hold opens Mission Control) and start the
    /// inactivity timer.
    private func armSpacesMode() {
        spacesModeActive = true
        restartSpacesModeTimer()
        rmDebug("🖥 Spaces Mode armed (\(spacesModeWindow)s window)")
    }

    /// Restart the inactivity timer: after `spacesModeWindow` seconds with no left/right switch,
    /// Spaces Mode disarms on its own (Mission Control is left as-is on a timeout — not closed).
    private func restartSpacesModeTimer() {
        spacesModeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.spacesModeTimer = nil
            self.spacesModeActive = false
            rmDebug("🖥 Spaces Mode timed out")
        }
        spacesModeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + spacesModeWindow, execute: work)
    }

    private func disarmSpacesMode() {
        spacesModeActive = false
        spacesModeTimer?.cancel()
        spacesModeTimer = nil
    }

    /// Fire a completed tap. With no `<key>.double` binding the single fires immediately (zero
    /// latency). With a `.double` binding the single is held for `doubleTapWindow`: the first tap
    /// schedules `<key>`; a 2nd tap inside the window cancels that pending single and fires
    /// `<key>.double` instead — so a double-tap emits ONLY the double, never a single too.
    private func fireTapOrDouble(_ buttonName: String, tapKey: String) {
        guard let controller = controller else { return }
        let doubleKey = tapKey + ".double"

        // No double binding → nothing to disambiguate; fire the single now.
        guard controller.hasBinding(for: doubleKey) else {
            if controller.handle(InputEvent(key: tapKey)) { print("🔘 \(tapKey) (config)") }
            return
        }

        if let pending = pendingSingle.removeValue(forKey: buttonName) {
            // 2nd tap within the window → it's a double. Cancel the queued single, fire the double.
            pending.cancel()
            if controller.handle(InputEvent(key: doubleKey)) { print("🔘 \(doubleKey) (config)") }
        } else {
            // 1st tap → hold the single; fire it only if no 2nd tap arrives within the window.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let controller = self.controller else { return }
                self.pendingSingle[buttonName] = nil
                if controller.handle(InputEvent(key: tapKey)) { print("🔘 \(tapKey) (config)") }
            }
            pendingSingle[buttonName] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        }
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            
            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }
    
    /// Map an identified HID button name to a config event key (`ring.*` for the
    /// click-ring, `button.*` for everything else).
    static func configKey(for buttonName: String) -> String {
        switch buttonName {
        case "ringUp":    return "ring.up"
        case "ringDown":  return "ring.down"
        case "ringLeft":  return "ring.left"
        case "ringRight": return "ring.right"
        default:          return "button.\(buttonName)"
        }
    }

    // MARK: - Button Identification

    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)
        case (0x0C, 0x42): return "ringUp"        // Menu Up — click-ring up
        case (0x0C, 0x43): return "ringDown"      // Menu Down — click-ring down
        case (0x0C, 0x44): return "ringLeft"      // Menu Left — click-ring left
        case (0x0C, 0x45): return "ringRight"     // Menu Right — click-ring right
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        if action.requiresHold {
            handleHoldAction(action, button: button, pressed: pressed)
            return
        }
        // Tap actions fire once, on press only.
        guard pressed else { return }
        switch action {
        case .none:
            break
        case .enterKey:
            sendKey(kVK_Return)
        case .upKey:
            sendKey(kVK_UpArrow)
        case .downKey:
            sendKey(kVK_DownArrow)
        case .escKey:
            sendKey(kVK_Escape)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .spaceKey, .rightCmd, .rightOpt:
            break // handled by handleHoldAction
        case .trackpadClick:
            cursorController.performClick()
        }
    }

    /// Press/release a virtual key mirroring the HID press duration (push-to-talk).
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .spaceKey: spec = (kVK_Space,        [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption,  .maskAlternate)
        default: return
        }

        if pressed {
            // Defensive: if a prior release was missed, close the stale hold before opening a new one.
            if let stale = heldKeys.removeValue(forKey: button) {
                postKey(keyCode: stale.keyCode, flags: [], keyDown: false)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
            heldKeys[button] = spec
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys() {
        for (_, held) in heldKeys {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
        heldKeys.removeAll()
        buttonState.removeAll()
        stopAllKeyRepeats()   // don't leak auto-repeat timers if the remote disconnects mid-hold
        disarmSpacesMode()    // and don't leave Spaces Mode armed with no device attached
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}
