import Cocoa

private let exitKeyCode: Int64 = 109 // F10
private let exitMediaKey = 7         // F10 when it is the mute key
private let triplePressGap: TimeInterval = 0.6
private let keepAwakeDefaultsKey = "keepAwakeWhileCovered"
private let keepScreenOnDefaultsKey = "keepScreenOn"
private let keepScreenOnUntilKey = "keepScreenOnUntil"
private let eventMask: CGEventMask = {
    let codes: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 25, 26, 27, 29, 30, 31, 32]
    return codes.reduce(0) { $0 | (1 << $1) }
}()

private let appDelegate = AppDelegate()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [(window: NSPanel, curtain: CurtainView)] = []
    private var permissionWindow: NSWindow?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clockTimer: Timer?
    private var topTimer: Timer?
    private var trustTimer: Timer?
    private var cursorHidden = false
    private var coverWhenTrusted = false
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var exitPressTimes: [TimeInterval] = []
    private var sleepActivity: NSObjectProtocol?
    private var keepAwakeItem: NSMenuItem?
    private var keepScreenOnItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var timedKeepAwakeItem: NSMenuItem?
    private var sleepTimer: Timer?
    private var durationWindow: NSWindow?
    private var durationField: NSTextField?
    private var durationUnits: NSPopUpButton?
    private var durationStopButton: NSButton?
    private var durationCancelButton: NSButton?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private let untilFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "ScreenCurtain")
        image?.isTemplate = true
        item.button?.image = image
        UserDefaults.standard.register(defaults: [keepAwakeDefaultsKey: true, keepScreenOnDefaultsKey: false])
        let menu = NSMenu()
        let cover = NSMenuItem(title: "Cover screen", action: #selector(coverScreen), keyEquivalent: "")
        cover.target = self
        let keepAwake = NSMenuItem(title: "Keep awake while covered", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.state = UserDefaults.standard.bool(forKey: keepAwakeDefaultsKey) ? .on : .off
        keepAwakeItem = keepAwake
        let keepScreenOn = NSMenuItem(title: "Keep screen on", action: #selector(toggleKeepScreenOn), keyEquivalent: "")
        keepScreenOn.target = self
        keepScreenOn.state = UserDefaults.standard.bool(forKey: keepScreenOnDefaultsKey) ? .on : .off
        keepScreenOnItem = keepScreenOn
        let forTime = NSMenuItem(title: "For a set time…", action: #selector(showDurationWindow), keyEquivalent: "")
        forTime.target = self
        let until = NSMenuItem(title: "Until", action: nil, keyEquivalent: "")
        until.isEnabled = false
        until.isHidden = true
        timedKeepAwakeItem = until
        let stop = NSMenuItem(title: "Stop keeping screen on", action: #selector(stopKeepingScreenOn), keyEquivalent: "")
        stop.target = self
        stop.isHidden = true
        stopMenuItem = stop
        let quit = NSMenuItem(title: "Quit", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(cover)
        menu.addItem(keepAwake)
        menu.addItem(keepScreenOn)
        menu.addItem(forTime)
        menu.addItem(until)
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        restoreTimedKeepAwake()
        updateStopVisibility()
        updateSleep()
        if AXIsProcessTrusted() { startHotkeyMonitor() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateTimedItem()
        updateStopVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopHotkeyMonitor()
        stopCurtain()
    }

    @objc private func coverScreen() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            coverWhenTrusted = true
            beginTrustWatch()
            return
        }
        startCurtain()
    }

    @objc private func toggleKeepAwake() {
        let enabled = !UserDefaults.standard.bool(forKey: keepAwakeDefaultsKey)
        UserDefaults.standard.set(enabled, forKey: keepAwakeDefaultsKey)
        keepAwakeItem?.state = enabled ? .on : .off
        updateSleep()
    }

    @objc private func toggleKeepScreenOn() {
        let enabled = !UserDefaults.standard.bool(forKey: keepScreenOnDefaultsKey)
        UserDefaults.standard.set(enabled, forKey: keepScreenOnDefaultsKey)
        keepScreenOnItem?.state = enabled ? .on : .off
        clearSleepTimer()
        updateStopVisibility()
        updateSleep()
    }

    @objc private func stopKeepingScreenOn() {
        UserDefaults.standard.set(false, forKey: keepScreenOnDefaultsKey)
        keepScreenOnItem?.state = .off
        clearSleepTimer()
        updateStopVisibility()
        updateSleep()
        closeDurationWindow()
    }

    @objc private func showDurationWindow() {
        if durationWindow != nil {
            updateStopVisibility()
            durationWindow?.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenCurtain"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Keep the screen on for")
        label.frame = NSRect(x: 20, y: 100, width: 300, height: 22)
        let field = NSTextField(frame: NSRect(x: 20, y: 62, width: 70, height: 24))
        field.stringValue = "1"
        let units = NSPopUpButton(frame: NSRect(x: 100, y: 58, width: 140, height: 28), pullsDown: false)
        units.addItems(withTitles: ["Hours", "Days"])
        let startButton = NSButton(title: "Start", target: self, action: #selector(startTimedKeepAwake))
        startButton.frame = NSRect(x: 20, y: 16, width: 90, height: 32)
        startButton.keyEquivalent = "\r"
        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopKeepingScreenOn))
        stopButton.frame = NSRect(x: 120, y: 16, width: 90, height: 32)
        durationStopButton = stopButton
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(closeDurationWindow))
        cancelButton.frame = NSRect(x: 220, y: 16, width: 90, height: 32)
        durationCancelButton = cancelButton
        let view = NSView(frame: window.contentView!.bounds)
        view.addSubview(label)
        view.addSubview(field)
        view.addSubview(units)
        view.addSubview(startButton)
        view.addSubview(stopButton)
        view.addSubview(cancelButton)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        durationWindow = window
        durationField = field
        durationUnits = units
        updateStopVisibility()
        window.makeFirstResponder(field)
        activateApp()
    }

    @objc private func closeDurationWindow() {
        durationWindow?.close()
        durationWindow = nil
        durationField = nil
        durationUnits = nil
        durationStopButton = nil
        durationCancelButton = nil
    }

    @objc private func startTimedKeepAwake() {
        let text = durationField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let count = Int(text), count >= 1, count <= 99 else { return }
        let hours = durationUnits?.indexOfSelectedItem == 1 ? count * 24 : count
        let end = Date().addingTimeInterval(TimeInterval(hours) * 3600)
        UserDefaults.standard.set(true, forKey: keepScreenOnDefaultsKey)
        UserDefaults.standard.set(end.timeIntervalSince1970, forKey: keepScreenOnUntilKey)
        keepScreenOnItem?.state = .on
        scheduleSleepTimer(until: end)
        updateTimedItem()
        updateStopVisibility()
        updateSleep()
        closeDurationWindow()
    }

    private func restoreTimedKeepAwake() {
        let until = UserDefaults.standard.double(forKey: keepScreenOnUntilKey)
        guard until > 0 else { return }
        let end = Date(timeIntervalSince1970: until)
        guard end > Date() else {
            finishTimedKeepAwake()
            return
        }
        UserDefaults.standard.set(true, forKey: keepScreenOnDefaultsKey)
        keepScreenOnItem?.state = .on
        scheduleSleepTimer(until: end)
        updateTimedItem()
        updateStopVisibility()
    }

    private func scheduleSleepTimer(until end: Date) {
        sleepTimer?.invalidate()
        let interval = end.timeIntervalSinceNow
        guard interval > 0 else {
            finishTimedKeepAwake()
            return
        }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.finishTimedKeepAwake()
        }
    }

    private func finishTimedKeepAwake() {
        clearSleepTimer()
        UserDefaults.standard.set(false, forKey: keepScreenOnDefaultsKey)
        keepScreenOnItem?.state = .off
        updateTimedItem()
        updateStopVisibility()
        updateSleep()
    }

    private func clearSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        UserDefaults.standard.removeObject(forKey: keepScreenOnUntilKey)
        updateTimedItem()
    }

    private func updateTimedItem() {
        let until = UserDefaults.standard.double(forKey: keepScreenOnUntilKey)
        let end = Date(timeIntervalSince1970: until)
        guard until > 0, end > Date() else {
            timedKeepAwakeItem?.isHidden = true
            return
        }
        timedKeepAwakeItem?.title = "Until \(untilFormatter.string(from: end))"
        timedKeepAwakeItem?.isHidden = false
    }

    private func updateStopVisibility() {
        let on = UserDefaults.standard.bool(forKey: keepScreenOnDefaultsKey)
        stopMenuItem?.isHidden = !on
        durationStopButton?.isHidden = !on
        durationCancelButton?.frame = NSRect(x: on ? 220 : 120, y: 16, width: 90, height: 32)
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func beginTrustWatch() {
        showPermissionWindow()
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionWindow?.close()
            self?.permissionWindow = nil
            self?.startHotkeyMonitor()
            guard self?.coverWhenTrusted == true else { return }
            self?.coverWhenTrusted = false
            self?.startCurtain()
        }
    }

    private func startHotkeyMonitor() {
        guard globalHotkeyMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .systemDefined]
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.notePossibleStart(event)
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.notePossibleStart(event)
            return event
        }
    }

    private func stopHotkeyMonitor() {
        if let globalHotkeyMonitor { NSEvent.removeMonitor(globalHotkeyMonitor) }
        if let localHotkeyMonitor { NSEvent.removeMonitor(localHotkeyMonitor) }
        globalHotkeyMonitor = nil
        localHotkeyMonitor = nil
        exitPressTimes.removeAll()
    }

    private func notePossibleStart(_ event: NSEvent) {
        guard tap == nil else { return }
        if isStartPress(event) {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = exitPressTimes.last, now - last < 0.08 { return }
            exitPressTimes.removeAll { now - $0 > triplePressGap * 2 }
            exitPressTimes.append(now)
            guard exitPressTimes.count >= 3 else { return }
            let times = Array(exitPressTimes.suffix(3))
            guard times[1] - times[0] <= triplePressGap, times[2] - times[1] <= triplePressGap else { return }
            exitPressTimes.removeAll()
            DispatchQueue.main.async { [weak self] in self?.coverScreen() }
            return
        }
        if breaksStartSequence(event) { exitPressTimes.removeAll() }
    }

    private func isStartPress(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            return !event.isARepeat && Int64(event.keyCode) == exitKeyCode
        }
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyState = (event.data1 & 0x0000FF00) >> 8
        let keyRepeat = event.data1 & 0x1
        return keyCode == exitMediaKey && keyState == 0xA && keyRepeat == 0
    }

    private func breaksStartSequence(_ event: NSEvent) -> Bool {
        if event.type == .keyDown { return true }
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyState = (event.data1 & 0x0000FF00) >> 8
        let keyRepeat = event.data1 & 0x1
        if keyRepeat != 0 || keyState != 0xA { return false }
        return keyCode != exitMediaKey
    }

    private func showPermissionWindow() {
        if permissionWindow != nil { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenCurtain"
        let text = NSTextField(wrappingLabelWithString: "macOS must allow this app to see the keyboard. In System Settings, turn on ScreenCurtain under Privacy & Security, Accessibility. If you also see Input Monitoring, turn it on there too. The cover starts when that is done.")
        text.frame = NSRect(x: 20, y: 70, width: 420, height: 90)
        let openButton = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        openButton.frame = NSRect(x: 20, y: 20, width: 140, height: 32)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePermission))
        closeButton.frame = NSRect(x: 170, y: 20, width: 80, height: 32)
        let view = NSView(frame: window.contentView!.bounds)
        view.addSubview(text)
        view.addSubview(openButton)
        view.addSubview(closeButton)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        permissionWindow = window
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func closePermission() {
        trustTimer?.invalidate()
        permissionWindow?.close()
        permissionWindow = nil
    }

    @objc private func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for text in urls {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }

    private func startCurtain() {
        guard tap == nil else { return }
        guard installTap() else {
            let alert = NSAlert()
            alert.messageText = "ScreenCurtain cannot watch the keyboard yet"
            alert.informativeText = "Turn on ScreenCurtain in Accessibility, then choose Cover screen again."
            alert.runModal()
            return
        }
        buildWindows()
        hideCursor()
        tick()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        topTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.keepOnTop() }
        updateSleep()
    }

    private func installTap() -> Bool {
        guard let created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask, callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = created
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let state = event.getIntegerValueField(.eventSourceStateID)
        let fromPerson = state == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        if !fromPerson { return Unmanaged.passUnretained(event) }
        if isExit(type: type, event: event) {
            DispatchQueue.main.async { [weak self] in self?.stopCurtain() }
        }
        return nil
    }

    private func isExit(type: CGEventType, event: CGEvent) -> Bool {
        if type == .keyDown {
            return event.getIntegerValueField(.keyboardEventKeycode) == exitKeyCode
        }
        guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue), let nsEvent = NSEvent(cgEvent: event) else {
            return false
        }
        guard nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else { return false }
        let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000FF00) >> 8
        return keyCode == exitMediaKey && keyState == 0xA
    }

    @objc private func screensChanged() {
        guard tap != nil else { return }
        buildWindows()
    }

    private func buildWindows() {
        for item in windows { item.window.close() }
        windows.removeAll()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isMovable = false
            let content = CurtainView(frame: panel.contentView?.bounds ?? screen.frame)
            panel.contentView = content
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            windows.append((panel, content))
        }
        tick()
    }

    private func tick() {
        let now = Date()
        let time = timeFormatter.string(from: now)
        let day = dateFormatter.string(from: now)
        for item in windows {
            item.curtain.refreshClock(time: time, day: day)
        }
    }

    private func keepOnTop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        for item in windows {
            item.window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            item.window.orderFrontRegardless()
        }
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func updateSleep() {
        let keepScreenOn = UserDefaults.standard.bool(forKey: keepScreenOnDefaultsKey)
        let keepWhileCovered = tap != nil && UserDefaults.standard.bool(forKey: keepAwakeDefaultsKey)
        if keepScreenOn || keepWhileCovered { preventSleep() } else { allowSleep() }
    }

    private func preventSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "ScreenCurtain is keeping the Mac awake")
    }

    private func allowSleep() {
        guard let sleepActivity else { return }
        ProcessInfo.processInfo.endActivity(sleepActivity)
        self.sleepActivity = nil
    }

    private func stopCurtain() {
        clockTimer?.invalidate()
        topTimer?.invalidate()
        clockTimer = nil
        topTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        showCursor()
        for item in windows { item.window.close() }
        windows.removeAll()
        updateSleep()
    }

    @objc private func quitNow() {
        stopHotkeyMonitor()
        stopCurtain()
        NSApp.terminate(nil)
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

final class CurtainView: NSView {
    let lockView = LockView()
    let timeLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")
    private let cluster = NSView()
    private var moveTimer: Timer?
    private var velocity = NSPoint(x: 40, y: 28)
    private var didPlace = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timeLabel.alignment = .center
        timeLabel.textColor = .white
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        dateLabel.alignment = .center
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        dateLabel.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        cluster.addSubview(lockView)
        cluster.addSubview(timeLabel)
        cluster.addSubview(dateLabel)
        addSubview(cluster)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        moveTimer?.invalidate()
    }

    func refreshClock(time: String, day: String) {
        timeLabel.stringValue = time
        dateLabel.stringValue = day
        layoutClusterContents()
        clampCluster()
    }

    override func layout() {
        super.layout()
        layoutClusterContents()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if !didPlace {
            didPlace = true
            cluster.setFrameOrigin(NSPoint(x: max(0, (bounds.width - cluster.frame.width) / 2), y: max(0, (bounds.height - cluster.frame.height) / 2)))
        } else {
            clampCluster()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moveTimer?.invalidate()
        moveTimer = nil
        guard window != nil else { return }
        let angle = CGFloat.random(in: 0..<(2 * .pi))
        let speed: CGFloat = 42
        velocity = NSPoint(x: cos(angle) * speed, y: sin(angle) * speed)
        if abs(velocity.x) < 14 { velocity.x = velocity.x < 0 ? -18 : 18 }
        if abs(velocity.y) < 14 { velocity.y = velocity.y < 0 ? -18 : 18 }
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.step(1.0 / 30.0)
        }
    }

    private func step(_ dt: CGFloat) {
        var origin = cluster.frame.origin
        origin.x += velocity.x * dt
        origin.y += velocity.y * dt
        let maxX = max(0, bounds.width - cluster.frame.width)
        let maxY = max(0, bounds.height - cluster.frame.height)
        if origin.x <= 0 {
            origin.x = 0
            velocity.x = abs(velocity.x)
        } else if origin.x >= maxX {
            origin.x = maxX
            velocity.x = -abs(velocity.x)
        }
        if origin.y <= 0 {
            origin.y = 0
            velocity.y = abs(velocity.y)
        } else if origin.y >= maxY {
            origin.y = maxY
            velocity.y = -abs(velocity.y)
        }
        cluster.setFrameOrigin(origin)
    }

    private func layoutClusterContents() {
        timeLabel.sizeToFit()
        dateLabel.sizeToFit()
        let textWidth = max(timeLabel.frame.width, dateLabel.frame.width, 120)
        let width = textWidth + 32
        let lockHeight: CGFloat = 80
        let timeHeight: CGFloat = 76
        let dateHeight = max(dateLabel.frame.height, 28)
        let gap: CGFloat = 12
        let height = lockHeight + gap + timeHeight + gap + dateHeight
        let origin = cluster.frame.origin
        cluster.frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
        lockView.frame = NSRect(x: (width - 80) / 2, y: height - lockHeight, width: 80, height: lockHeight)
        timeLabel.frame = NSRect(x: 0, y: dateHeight + gap, width: width, height: timeHeight)
        dateLabel.frame = NSRect(x: 0, y: 0, width: width, height: dateHeight)
    }

    private func clampCluster() {
        let maxX = max(0, bounds.width - cluster.frame.width)
        let maxY = max(0, bounds.height - cluster.frame.height)
        var origin = cluster.frame.origin
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        cluster.setFrameOrigin(origin)
    }
}

final class LockView: NSView {
    required init?(coder: NSCoder) { nil }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setStroke()
        let shackle = NSBezierPath()
        shackle.lineWidth = 5
        shackle.lineCapStyle = .round
        shackle.appendArc(withCenter: NSPoint(x: 40, y: 46), radius: 16, startAngle: 0, endAngle: 180, clockwise: false)
        shackle.stroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 16, y: 8, width: 48, height: 40), xRadius: 4, yRadius: 4)
        body.lineWidth = 5
        body.stroke()
    }
}

autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = appDelegate
    app.run()
}
