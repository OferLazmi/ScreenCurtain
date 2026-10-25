import Cocoa

private let exitKeyCode: Int64 = 109 // F10
private let exitMediaKey = 7         // F10 when it is the mute key
private let triplePressGap: TimeInterval = 0.6
private let eventMask: CGEventMask = {
    let codes: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 18, 19, 20, 22, 25, 26, 27, 29, 30, 31, 32]
    return codes.reduce(0) { $0 | (1 << $1) }
}()

private let appDelegate = AppDelegate()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [(window: NSPanel, timeLabel: NSTextField, dateLabel: NSTextField)] = []
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "ScreenCurtain")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        let cover = NSMenuItem(title: "Cover screen", action: #selector(coverScreen), keyEquivalent: "")
        cover.target = self
        let quit = NSMenuItem(title: "Quit", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(cover)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        if AXIsProcessTrusted() { startHotkeyMonitor() }
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
            windows.append((panel, content.timeLabel, content.dateLabel))
        }
        tick()
    }

    private func tick() {
        let now = Date()
        let time = timeFormatter.string(from: now)
        let day = dateFormatter.string(from: now)
        for item in windows {
            item.timeLabel.stringValue = time
            item.dateLabel.stringValue = day
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timeLabel.alignment = .center
        timeLabel.textColor = .white
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .light)
        dateLabel.alignment = .center
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        dateLabel.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        addSubview(lockView)
        addSubview(timeLabel)
        addSubview(dateLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        lockView.frame = NSRect(x: bounds.midX - 40, y: bounds.midY + 10, width: 80, height: 80)
        timeLabel.frame = NSRect(x: 0, y: bounds.midY - 80, width: bounds.width, height: 76)
        dateLabel.frame = NSRect(x: 0, y: bounds.midY - 120, width: bounds.width, height: 28)
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
