//
//  TouchHandler.swift
//  HyperVibe
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import AppKit
import Darwin

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(touches: touches, count: numTouches, timestamp: timestamp)
}

class TouchHandler {
    
    /// mach_absolute_time() is in machine-dependent units; convert to seconds via timebase.
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        if mach_timebase_info(&info) == 0 {
            return (info.numer, info.denom)
        }
        return (1, 1)
    }()
    
    private static func machDeltaToSeconds(from startMach: UInt64) -> Double {
        guard startMach > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= startMach ? (now - startMach) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private let cursorController: CursorController
    private var device: MTDevice?
    private var reconnectTimer: Timer?
    private var fastReconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    
    var scrollScale: CGFloat = 150.0
    
    private var lastTouchPosition: CGPoint?
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0
    private var touchStartTime: UInt64 = 0
    private var touchStartPosition: CGPoint = .zero
    
    private let cursorScale: CGFloat = 500.0
    /// Cursor speed multiplier (config: settings.cursorSpeed). Lower = less sensitive.
    var cursorSpeed: CGFloat = 1.0
    /// Per-frame jitter deadzone (config: settings.cursorDeadzone). Movement below this
    /// (normalized) is ignored so resting/pressing a finger doesn't drift the cursor.
    var cursorDeadzone: CGFloat = 0.006
    /// Circular-scroll (iPod wheel) config; all params are config-tunable and hot-reloadable.
    var circularConfig: CircularScrollConfig = .default {
        didSet { circularDetector.update(config: circularConfig) }
    }
    private let circularDetector = CircularScrollDetector(config: .default)
    private var circularActive = false
    /// Set once this touch scrolls (circular or two-finger). A scrolling touch can NEVER also
    /// fire a swipe or tap — scroll and swipe are mutually exclusive within one touch.
    private var didScroll = false
    /// Sub-pixel accumulator so smooth continuous rotation emits whole scroll pixels as they add up.
    private var scrollRemainder: Double = 0
    /// Press-to-click freeze: contact grows when you press to click; freeze the cursor so the
    /// growing thumb contact doesn't drift the pointer. Value is the contact-rise fraction over
    /// the resting baseline that counts as "pressing".
    var clickSteadiness: Double = 0.6
    private var contactBaseline: Float = 0
    /// Position-follow smoothing for circular scroll: total scroll always equals total rotation ×
    /// speed (never over/under), and each frame eases toward that target so jittery hand circling
    /// still scrolls smoothly. `scrollEase` = how fast it catches up (smaller = smoother/laggier).
    private var rotationTotal: Double = 0
    private var scrollEmitted: Double = 0
    var scrollEase: Double = 0.3
    private let tapMaxDuration: Double = 0.22
    private let tapMaxDistance: CGFloat = 0.07
    // Swipe detection: velocity-gated single-finger flick. Distance > 35% of trackpad in < 350ms,
    // with the dominant axis at least 2× the orthogonal axis (rejects diagonal wobble).
    private let swipeMinDistance: CGFloat = 0.35
    private let swipeMaxDuration: Double = 0.35
    private let swipeAxisRatio: CGFloat = 2.0
    private var hadMultipleFingersInSession = false

    /// Fired on touch-up when a single-finger flick is detected. Dispatched on main.
    var onSwipe: ((SwipeDirection) -> Void)?
    /// Fired on touch-up for a still two-finger tap (a two-finger drag scrolls instead).
    var onTwoFingerTap: (() -> Void)?
    /// Highest finger count seen this touch session (to classify two-finger gestures on lift).
    private var sessionMaxFingers = 0
    private let reconnectInterval: TimeInterval = 2.0
    private let idleTimeout: TimeInterval = 90.0
    private let touchStarvationThreshold: TimeInterval = 15.0

    init(cursorController: CursorController) {
        self.cursorController = cursorController
    }
    
    deinit {
        stop()
    }
    
    func start() {
        findAndStartDevice()
        startReconnectTimer()
        // Restart MT device after sleep (trackpad stops delivering until restarted).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartTrackpadAfterWake()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        fastReconnectTimer?.invalidate()
        fastReconnectTimer = nil
        stopDevice()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// only when we don't have a device, so we can reattach if it reappeared. If we already
    /// have a working device, do nothing — restarting on every button press would break the trackpad.
    func tryReconnectTrackpad() {
        guard device == nil else { return }
        let doScan = { [weak self] in
            guard self?.device == nil else { return }
            self?.findAndStartDevice()
        }
        if Thread.isMainThread {
            doScan()
        } else {
            DispatchQueue.main.async { doScan() }
        }
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // Poll more often for a limited time so we attach as soon as the trackpad reappears.
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.device != nil {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndStartDevice()
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopDevice()
        findAndStartDevice()
    }
    
    private func describe(_ dev: MTDevice) -> String {
        let builtIn = MTDeviceIsBuiltIn(dev)
        var devID: UInt64 = 0; MTDeviceGetDeviceID(dev, &devID)
        var fam: Int32 = 0; MTDeviceGetFamilyID(dev, &fam)
        var w: Int32 = 0, h: Int32 = 0; MTDeviceGetSensorSurfaceDimensions(dev, &w, &h)
        return "builtIn=\(builtIn) id=\(devID) family=\(fam) surface=\(w)x\(h)"
    }

    /// The Siri Remote clickpad is a small square (~2775×2775 in 0.01 mm units); trackpads are
    /// far larger (>12000 on the long axis). Match the remote by its small surface so we never
    /// accidentally attach to a Magic Trackpad or the built-in trackpad.
    private func isRemoteSurface(_ dev: MTDevice) -> Bool {
        var w: Int32 = 0, h: Int32 = 0
        MTDeviceGetSensorSurfaceDimensions(dev, &w, &h)
        let maxDim = max(w, h)
        return maxDim > 0 && maxDim < 6000
    }

    private func findAndStartDevice() {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceList = cfArray as [MTDevice]
        rmDebug("📱 MTDeviceCreateList: \(deviceList.count) device(s)")
        for (i, dev) in deviceList.enumerated() {
            rmDebug("📱   [\(i)] \(describe(dev))")
        }
        // Attach to the remote specifically (small surface), never a trackpad.
        if let remote = deviceList.first(where: { !MTDeviceIsBuiltIn($0) && isRemoteSurface($0) }) {
            rmDebug("📱 selecting remote (small surface): \(describe(remote))")
            startDevice(remote)
            return
        }
        // No remote-sized device present: do not hijack a trackpad; wait for the remote to appear.
        rmDebug("📱 no remote-sized multitouch device found; not attaching")
        if device != nil { stopDevice() }
    }
    
    private func startDevice(_ dev: MTDevice) {
        stopDevice()
        device = dev
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        print("📱 Trackpad device connected and started")
    }
    
    private func stopDevice() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        device = nil
        
        print("📱 Trackpad device disconnected")
        lastTouchPosition = nil
        lastTouchCount = 0
        hadMultipleFingersInSession = false
    }
    
    private func startReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        // Fire when app is in background (menu bar only); otherwise timer may not run.
        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func checkAndReconnect() {
        let timeSinceLastTouch = lastTouchTime == 0 ? 0 : Self.machDeltaToSeconds(from: lastTouchTime)

        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceCount = CFArrayGetCount(cfArray)

        // Restart if we have a device ref but the driver stopped (e.g. after remote sleep).
        if let dev = device, !MTDeviceIsRunning(dev) {
            findAndStartDevice()
            return
        }
        // Restart if we have a device but no touch events for a while (remote slept; no "remote wake" API).
        if device != nil && timeSinceLastTouch > touchStarvationThreshold {
            findAndStartDevice()
            return
        }
        if device == nil || (timeSinceLastTouch > idleTimeout && deviceCount > 1) {
            findAndStartDevice()
        }
    }
    
    func handleTouches(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        lastTouchTime = mach_absolute_time()

        guard count > 0, let touchPtr = touches else {
            // Touch ended
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        // Calculate average position of all active touches
        var avgX: Float = 0
        var avgY: Float = 0
        var activeTouchCount = 0
        var contactSize: Float = 0   // total contact "quality"/pressure — grows when you press to click

        for i in 0..<count {
            let touch = touchPtr[i]

            // Only process active touches
            if touch.state == MTTouchStateTouching || touch.state == MTTouchStateMakeTouch {
                avgX += touch.normalizedVector.position.x
                avgY += touch.normalizedVector.position.y
                contactSize += touch.zTotal
                activeTouchCount += 1
            }
        }
        
        guard activeTouchCount > 0 else {
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        if activeTouchCount >= 2 {
            hadMultipleFingersInSession = true
        }
        sessionMaxFingers = max(sessionMaxFingers, activeTouchCount)

        avgX /= Float(activeTouchCount)
        avgY /= Float(activeTouchCount)
        
        let currentPos = CGPoint(x: CGFloat(avgX), y: CGFloat(avgY))
        
        // Handle touch start
        if lastTouchPosition == nil {
            rmDebug("📱 touch begin: fingers=\(activeTouchCount) pos=(\(avgX), \(avgY)) contact=\(contactSize)")
            hadMultipleFingersInSession = false
            circularActive = false
            didScroll = false
            scrollRemainder = 0
            rotationTotal = 0
            scrollEmitted = 0
            contactBaseline = contactSize
            circularDetector.reset()
            sessionMaxFingers = activeTouchCount
            touchStartTime = mach_absolute_time()
            touchStartPosition = currentPos
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }
        
        // Calculate delta
        let deltaX = currentPos.x - (lastTouchPosition?.x ?? currentPos.x)
        let deltaY = currentPos.y - (lastTouchPosition?.y ?? currentPos.y)

        // Process based on finger count: 1 finger = cursor, 2 fingers = scroll
        if activeTouchCount == 1 && lastTouchCount == 1 {
            // Circular scroll (outer ring) preempts the cursor once rotation passes threshold.
            if circularConfig.enabled {
                let radians = circularDetector.feed(x: Double(currentPos.x), y: Double(currentPos.y))
                if radians != 0 { circularActive = true; didScroll = true }
                if circularActive {
                    // Position-follow: total scroll tracks total rotation exactly (never faster),
                    // but eased each frame so jittery circling still scrolls smoothly.
                    rotationTotal += Double(radians)
                    let target = rotationTotal * circularConfig.pixelsPerRadian
                    let step = (target - scrollEmitted) * scrollEase
                    scrollEmitted += step
                    emitCircularScroll(pixels: step)
                    lastTouchPosition = currentPos
                    lastTouchCount = activeTouchCount
                    return
                }
            }
            // Press-to-click freeze: when a physical click is active, or the finger presses harder
            // (contact grows past the resting baseline), don't move the cursor — the growing thumb
            // contact would otherwise drag the pointer down as you press. Re-anchor so it resumes
            // cleanly when the press ends.
            let pressing = contactBaseline > 0 && contactSize > contactBaseline * Float(1 + clickSteadiness)
            if cursorController.isClickActive || pressing {
                lastTouchPosition = currentPos
                lastTouchCount = activeTouchCount
                return
            }
            // Track the resting contact level only while not pressing.
            contactBaseline += (contactSize - contactBaseline) * 0.15

            // Jitter deadzone: ignore sub-threshold frames and keep the anchor so slow
            // deliberate motion still accumulates across frames, but tremor nets ~zero.
            if hypot(deltaX, deltaY) < cursorDeadzone {
                lastTouchCount = activeTouchCount
                return
            }
            rmDebug(String(format: "🖱 d=(%.4f,%.4f) contact=%.3f base=%.3f click=%d",
                           deltaX, deltaY, contactSize, contactBaseline, cursorController.isClickActive ? 1 : 0))
            let clamped = moveCursor(deltaX: deltaX, deltaY: deltaY)
            // Only advance touch tracking if cursor wasn't clamped in that direction
            if let lastPos = lastTouchPosition {
                let adjustedDeltaX = clamped.clampedX ? 0 : deltaX
                let adjustedDeltaY = clamped.clampedY ? 0 : deltaY
                lastTouchPosition = CGPoint(
                    x: lastPos.x + adjustedDeltaX,
                    y: lastPos.y + adjustedDeltaY
                )
            } else {
                lastTouchPosition = currentPos
            }
        } else if activeTouchCount == 2 && lastTouchCount == 2 {
            // Two fingers: always scroll regardless of mode
            performScroll(deltaX: deltaX, deltaY: deltaY)
            if hypot(deltaX, deltaY) > 0.004 { didScroll = true }
            lastTouchPosition = currentPos
        } else {
            lastTouchPosition = currentPos
        }
        
        lastTouchCount = activeTouchCount
    }
    
    /// Classify a flick delta into a swipe direction (nil if too diagonal).
    /// y increases toward the top of the trackpad in MultitouchSupport coordinates.
    private func swipeDirection(dx: CGFloat, dy: CGFloat) -> SwipeDirection? {
        let absDx = abs(dx), absDy = abs(dy)
        if absDx > absDy * swipeAxisRatio { return dx > 0 ? .right : .left }
        if absDy > absDx * swipeAxisRatio { return dy > 0 ? .up : .down }
        return nil
    }

    private func handleTouchEnd() {
        guard lastTouchPosition != nil else { return }

        // Hard rule: if this touch scrolled (circular ring or two-finger), it is ONLY a scroll —
        // never also a swipe or tap. Scroll and swipe are mutually exclusive within one touch.
        if didScroll {
            didScroll = false
            circularActive = false
            return
        }

        // Don't trigger tap if physical click button is active
        if cursorController.isClickActive {
            return
        }
        let duration = Self.machDeltaToSeconds(from: touchStartTime)
        let dx = (lastTouchPosition?.x ?? 0) - touchStartPosition.x
        let dy = (lastTouchPosition?.y ?? 0) - touchStartPosition.y
        let movement = hypot(dx, dy)

        // Two fingers that did NOT scroll → a quick still two-finger tap (right-click by default).
        // A two-finger drag scrolled and was already handled by the didScroll lock above.
        if sessionMaxFingers >= 2 {
            if duration < tapMaxDuration, movement < tapMaxDistance {
                DispatchQueue.main.async { [weak self] in self?.onTwoFingerTap?() }
            }
            return
        }

        // One-finger swipe (flick). Distance threshold is well above tapMaxDistance, so a swipe
        // can never also register as a tap.
        if duration < swipeMaxDuration, movement > swipeMinDistance,
           let direction = swipeDirection(dx: dx, dy: dy) {
            DispatchQueue.main.async { [weak self] in self?.onSwipe?(direction) }
            return
        }

        if duration < tapMaxDuration && movement < tapMaxDistance {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cursorController.performClick()
            }
        }
    }
    
    private func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let scaledX = deltaX * cursorScale * cursorSpeed
        let scaledY = -deltaY * cursorScale * cursorSpeed

        var clamped = (clampedX: false, clampedY: false)

        if Thread.isMainThread {
            clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
        } else {
            DispatchQueue.main.sync {
                clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
            }
        }

        return clamped
    }
    
    /// Emit smooth circular scroll: carry the sub-pixel remainder so a steady rotation scrolls
    /// evenly instead of stepping between whole pixels.
    private func emitCircularScroll(pixels: Double) {
        scrollRemainder += pixels
        let whole = scrollRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRemainder -= whole
        let dy = Int32(whole)
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: 0, deltaY: dy)
        }
    }

    private func performScroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollX = Int32(-deltaX * scrollScale)
        let scrollY = Int32(deltaY * scrollScale)
        
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: scrollX, deltaY: scrollY)
        }
    }
}
