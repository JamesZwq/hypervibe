//
//  SiriRemoteApp.swift
//  HyperVibe
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?

    // Config engine (SiriRemoteCore)
    private var controller: Controller?
    private var appWatcher: AppWatcher?
    private var configWatcher: ConfigFileWatcher?

    // Settings UI
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 HyperVibe starting...")

        // Headless self-QC: `--snapshot-layout <path>` renders the Layout settings view to a PNG
        // and exits, without seizing the remote or opening a window.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-layout"),
           idx + 1 < CommandLine.arguments.count {
            LayoutSnapshot.renderAndExit(to: CommandLine.arguments[idx + 1])
            return
        }

        // Bluetooth AVRCP play/pause signals bypass cghidEventTap and reach com.apple.rcd
        // directly, which launches Music.app. Suspend rcd for this session; restored on exit.
        RCDControl.suspend()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        
        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )

        // --- Config engine (SiriRemoteCore): config bindings override native button behavior;
        //     unbound buttons fall through to HyperVibe's native mapping. ---
        let config = ConfigStore.loadConfig()

        // Tuning: the Settings window (UserDefaults) is the source of truth, seeded once from
        // the config file's settings block.
        let model = SettingsModel(initial: TuneStore.load() ?? TuneSettings(seed: config.settings))
        model.onApply = { [weak self] tune in self?.applyTune(tune) }
        model.config = config   // publish the live config to the Settings "Layout" tab
        settingsModel = model
        let settingsWin = SettingsWindowController(model: model)
        settingsWindow = settingsWin
        menuBarManager.onOpenSettings = { [weak settingsWin] in settingsWin?.show() }
        // Convenience: `./HyperVibe --settings` pops the window open immediately.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { settingsWin.show() }
        }

        let engineController = Controller(
            engine: MappingEngine(config: config),
            executor: MacActionExecutor()
        )
        controller = engineController
        remoteInputHandler?.controller = engineController
        appWatcher = AppWatcher { [weak engineController] bundleID in
            rmDebug("🎯 frontmost app → \(bundleID)")
            engineController?.frontmostAppChanged(bundleID: bundleID)
        }
        configWatcher = ConfigFileWatcher(url: ConfigStore.path) { [weak self] in
            let reloaded = ConfigStore.loadConfig()
            self?.controller?.reload(config: reloaded)
            self?.settingsModel?.config = reloaded   // keep the Layout tab in sync on hot-reload
            print("♻️ siriRemote config reloaded")
        }
        print("🧩 siriRemote config engine active — \(ConfigStore.path.path)")

        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        touchHandler?.onSwipe = { [weak self] direction in
            // Swipes are config-driven only. An unbound swipe does nothing — no native fallback,
            // so HyperVibe's Claude-Code default swipe keys (e.g. right = Shift+Tab) no longer
            // fire and cause the system beep. Bind swipe.<dir> in the config to use them.
            let key = "swipe.\(direction.rawValue)"
            if self?.controller?.handle(InputEvent(key: key)) == true {
                print("👆 \(key) (config)")
            }
        }
        touchHandler?.onTwoFingerTap = { [weak self] in
            // Config-driven only: unbound two-finger tap does nothing. Bind tap.two to use it.
            if self?.controller?.handle(InputEvent(key: "tap.two")) == true {
                print("👐 tap.two (config)")
            }
        }
        touchHandler?.start()
        applyTune(model.tune)   // touchHandler + remoteInputHandler now exist — push the tuning
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
                self?.settingsModel?.connected = (device != nil)
            }
        }
        remoteDetector?.startDetection()
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
    }
    
    /// Push cursor-feel settings from config into the touch handler (also called on hot reload).
    /// Push UI tuning values into the running touch handler (initial + on every settings change).
    private func applyTune(_ t: TuneSettings) {
        touchHandler?.cursorSpeed = CGFloat(t.cursorSpeed)
        touchHandler?.cursorDeadzone = CGFloat(t.cursorDeadzone)
        touchHandler?.accelMin = CGFloat(t.accelMin)
        touchHandler?.accelMax = CGFloat(t.accelMax)
        touchHandler?.accelLowSpeed = CGFloat(t.accelLowSpeed)
        touchHandler?.accelHighSpeed = CGFloat(t.accelHighSpeed)
        touchHandler?.clickRiseThreshold = t.clickRiseThreshold
        touchHandler?.pressMoveMax = t.pressMoveMax
        touchHandler?.circularConfig = t.circularConfig
        remoteInputHandler?.holdThreshold = t.holdThreshold
        remoteInputHandler?.doubleTapWindow = t.doubleTapWindow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        RCDControl.restore()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        // Consume a media key ONLY when it's the remote's own AND the config binds it — the HID
        // path already ran the bound action, so we suppress this duplicate. Unbound remote media
        // keys (e.g. volume, which is left native) pass through so the system does its native thing
        // (change volume, play/pause). Keyboard/other-device media keys (fromRemote=false) also
        // pass through. (true = consume, false = pass through.)
        let fromRemote = RemoteInputHandler.lastProcessedButton == buttonName
            && Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime) < 0.3
        let bound = controller?.hasBinding(for: "button.\(buttonName)") ?? false
        return fromRemote && bound
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        // macOS will show its own prompt when needed
        // No need for redundant custom alert
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Suspends `com.apple.rcd` (Remote Control Daemon) for the user's GUI launchd domain while
/// HyperVibe is running. rcd is what reacts to Bluetooth AVRCP play signals by launching
/// Music.app — a channel that bypasses HID seize and the cghidEventTap entirely. `bootout`
/// only affects this login session; restored on clean exit, and on next login either way.
enum RCDControl {
    private static let plistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
    private static var suspended = false

    static func suspend() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard isLoaded(service: service) else {
            print("ℹ️ com.apple.rcd not loaded; skipping suspend")
            return
        }
        let (status, err) = run(["bootout", service])
        if status == 0 {
            suspended = true
            print("🔇 com.apple.rcd suspended (Music won't auto-launch from BT remote)")
        } else {
            print("⚠️ Could not suspend com.apple.rcd (launchctl exit=\(status)): \(err)")
        }
    }

    static func restore() {
        guard suspended else { return }
        let domain = "gui/\(getuid())"
        let (status, err) = run(["bootstrap", domain, plistPath])
        if status == 0 {
            print("🔊 com.apple.rcd restored")
        } else {
            print("⚠️ Could not restore com.apple.rcd (launchctl exit=\(status)): \(err) — next login will re-register it")
        }
        suspended = false
    }

    private static func isLoaded(service: String) -> Bool {
        let (status, _) = run(["print", service], captureStderr: false)
        return status == 0
    }

    private static func run(_ args: [String], captureStderr: Bool = true) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = captureStderr ? errPipe : Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = captureStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, "\(error)")
        }
    }
}
