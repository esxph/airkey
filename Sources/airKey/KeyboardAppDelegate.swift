import AppKit
import Combine
import SwiftUI

final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class KeyboardHostingView: NSHostingView<ContentView> {
    override func menu(for event: NSEvent) -> NSMenu? { menu }
}

@MainActor
final class KeyboardAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let camera = CameraManager()
    let keyboard = TypingController(profileURL: PersonalProfileStore.defaultURL)
    let output = SystemTypingDriver()
    private var panel: KeyboardPanel?
    private var corner: KeyboardPanel?
    private var practice: NSWindow?
    private var restoreFrame: NSRect?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var idleTask: Task<Void, Never>?
    private var visibility = KeyboardVisibility()
    private var presented: KeyboardVisibility.State = .hidden
    private var menuOpen = false
    private var mouseMoving = false
    private var movement = KeyboardMovement()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        keyboard.useCompactKeyboard()
        visibility.fadeEnabled = preference("fade")
        visibility.tuckEnabled = preference("tuck")
        visibility.fullScreenEnabled = preference("fullScreen")
        keyboard.userActivity = { [weak self] in self?.activity() }
        keyboard.windowDrag = { [weak self] event in self?.moveKeyboard(event) }
        keyboard.prepareExternalInput = { [weak self] in
            guard let self else { return }; self.output.prepare(self.keyboard)
        }
        keyboard.outputTextChange = { [weak self] old, new in self?.output.emit(from: old, to: new) ?? false }
        keyboard.deleteExternalCharacter = { [weak self] in self?.output.deleteCharacter() }
        camera.frames.$frame.sink { [weak self] frame in
            guard let self else { return }
            let wasVisible = self.visibility.state == .visible
            self.visibility.observe(frame, size: self.keyboard.sceneSize, hasPress: !self.keyboard.pressed.isEmpty)
            self.applyPresentation()
            // A hidden key cannot type. The open-hand movement that restores
            // the panel is consumed; a subsequent fresh pinch can type.
            if wasVisible, self.visibility.state == .visible, !self.mouseMoving, !self.menuOpen {
                self.keyboard.process(frame)
            }
        }.store(in: &subscriptions)
        Publishers.CombineLatest(camera.$isRunning.removeDuplicates(), output.$needsPermission.removeDuplicates())
            .sink { [weak self] running, permission in self?.updateStatus(running: running, needsPermission: permission) }
            .store(in: &subscriptions)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        updateStatus(running: false, needsPermission: output.needsPermission)
        showKeyboard()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        // One low-frequency timer for permission refresh and presentation only.
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.output.refreshPermission()
                let busy = self.mouseMoving || self.menuOpen || self.keyboard.benchmark != nil || self.keyboard.isDecoding || !self.keyboard.pressed.isEmpty
                let shown = self.visibility.state == .visible || self.visibility.state == .faded
                // Never poll another app's AX tree during active typing. Check
                // editable focus only when an idle full-screen tuck is possible.
                let fullScreen = shown && !busy && self.now - self.visibility.lastActivity >= 2
                    && self.visibility.fullScreenEnabled && FullScreenMonitor.isFullScreen(on: self.panel?.screen)
                if fullScreen { self.output.refreshStatus() }
                self.visibility.update(at: self.now, fullScreen: fullScreen, editing: self.output.hasEditableFocus,
                    busy: busy)
                self.applyPresentation()
            }
        }
    }

    private func preference(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "presentation.\(key)") as? Bool ?? true
    }
    private func save(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: "presentation.\(key)") }
    private func activity() { visibility.activity(at: now); applyPresentation() }

    private func updateStatus(running: Bool, needsPermission: Bool) {
        let image = NSImage(systemSymbolName: running ? "keyboard.fill" : "keyboard", accessibilityDescription: "AirKey menu")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = needsPermission ? "AirKey — enable Accessibility to type into apps" : (running ? "AirKey — ready" : "AirKey — camera paused")
    }

    private func createPanel() {
        guard panel == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 1100, height: CGFloat = 444
        let area = screen.visibleFrame
        var frame = NSRect(x: area.midX - width / 2, y: area.minY + 18, width: width, height: height)
        if let saved = UserDefaults.standard.array(forKey: "presentation.origin") as? [Double], saved.count == 2,
           saved.allSatisfy(\.isFinite) {
            frame.origin = CGPoint(x: saved[0], y: saved[1])
            frame = constrained(frame)
        }
        let window = KeyboardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(window)
        window.title = "AirKey"
        window.isMovableByWindowBackground = true
        let host = KeyboardHostingView(rootView: ContentView(camera: camera, keyboard: keyboard, output: output,
            onActivity: { [weak self] in self?.activity() }, onMouseDrag: { [weak self] moving in self?.mouseDrag(moving) }))
        let contextMenu = NSMenu(); contextMenu.delegate = self; contextMenu.autoenablesItems = false
        host.menu = contextMenu
        window.contentView = host
        window.delegate = self
        panel = window
        restoreFrame = frame
        keyboard.setSceneSize(CGSize(width: width, height: height))
    }

    private func configure(_ window: KeyboardPanel) {
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func showCorner() {
        if corner == nil {
            let window = KeyboardPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 46),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(window); window.title = "Show AirKey"
            window.contentView = NSHostingView(rootView:
                Button { [weak self] in self?.showKeyboard() } label: {
                    Image(systemName: "keyboard").font(.system(size: 23))
                        .foregroundStyle(Color(red: 0.6, green: 0.85, blue: 0.96))
                        .frame(width: 60, height: 46)
                        .background(Color(red: 0.07, green: 0.12, blue: 0.17).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18)))
                }.buttonStyle(.plain).accessibilityLabel("Show AirKey keyboard").help("Show keyboard and resume hand tracking"))
            corner = window
        }
        let area = (panel?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        corner?.setFrameOrigin(NSPoint(x: area.maxX - 76, y: area.minY + 16))
        corner?.orderFrontRegardless()
    }

    @objc func showKeyboard() {
        createPanel()
        visibility.show(at: now)
        applyPresentation()
        panel?.orderFrontRegardless()
        camera.start()
        keyboard.refreshSuggestions()
    }

    private func applyPresentation() {
        let next = visibility.state
        guard next != presented else { return }
        let old = presented; presented = next
        switch next {
        case .visible:
            corner?.orderOut(nil)
            panel?.ignoresMouseEvents = false
            if old == .hidden || old == .tucked || old == .faded {
                if let frame = restoreFrame { panel?.setFrame(frame, display: true) }
                panel?.orderFrontRegardless()
                keyboard.refreshSuggestions()
            }
            animate { self.panel?.animator().alphaValue = 0.78 }
        case .faded:
            restoreFrame = panel?.frame
            panel?.ignoresMouseEvents = true
            keyboard.cancelInput(); output.reset()
            showCorner()
            animate({ self.panel?.animator().alphaValue = 0 }) { [weak self] in
                guard let self, self.visibility.state == .faded else { return }
                self.panel?.orderOut(nil)
            }
        case .tucked:
            restoreFrame = panel?.frame
            panel?.ignoresMouseEvents = true
            pauseInput()
            showCorner()
            animate({ self.panel?.animator().alphaValue = 0 }) { [weak self] in
                guard let self, self.visibility.state == .tucked else { return }
                self.panel?.orderOut(nil)
            }
        case .hidden:
            panel?.orderOut(nil); corner?.orderOut(nil)
            pauseInput()
        }
    }

    private func animate(_ changes: @escaping () -> Void, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            changes()
        } completionHandler: { Task { @MainActor in completion() } }
    }

    private func pauseInput() {
        camera.stop(); keyboard.cancelInput(); output.reset()
        movement.pause()
    }

    private func moveKeyboard(_ event: KeyboardDragEvent) {
        guard let panel else { return }
        switch event {
        case .began(let point):
            activity(); movement.begin(at: point, origin: panel.frame.origin)
        case .moved(let point):
            guard let origin = movement.move(to: point, currentOrigin: panel.frame.origin) else { return }
            let proposed = NSRect(origin: origin, size: panel.frame.size)
            let frame = constrained(proposed)
            if panel.frame.origin.distance(to: frame.origin) >= 0.5 { panel.setFrameOrigin(frame.origin) }
        case .paused: movement.pause()
        case .ended: movement.pause(); persistPlacement()
        }
    }

    private func mouseDrag(_ moving: Bool) {
        mouseMoving = moving
        if moving { keyboard.cancelInput(); movement.pause(); activity() }
        else if let panel {
            panel.setFrame(constrained(panel.frame), display: true)
            persistPlacement(); activity(); keyboard.refreshSuggestions()
        }
    }

    private func constrained(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            let aRect = a.visibleFrame.intersection(frame), bRect = b.visibleFrame.intersection(frame)
            return (aRect.isNull ? 0 : aRect.width * aRect.height) < (bRect.isNull ? 0 : bRect.width * bRect.height)
        } ?? NSScreen.main
        return screen.map { KeyboardMovement.constrain(frame, to: $0.visibleFrame) } ?? frame
    }

    private func persistPlacement() {
        guard let frame = panel?.frame else { return }
        restoreFrame = frame
        UserDefaults.standard.set([Double(frame.minX), Double(frame.minY)], forKey: "presentation.origin")
    }
    @objc func hideKeyboard() {
        keyboard.cancelBenchmark(); practice?.orderOut(nil)
        visibility.hide(); applyPresentation()
    }
    private func tuckKeyboard() { visibility.tuck(); applyPresentation() }

    func menuWillOpen(_ menu: NSMenu) {
        keyboard.cancelGestures()
        menuOpen = true; activity(); output.refreshStatus(); rebuild(menu)
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ command: String? = nil, checked: Bool? = nil, enabled: Bool = true, to parent: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: command == nil ? nil : #selector(performMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command; item.isEnabled = enabled && command != nil
            if let checked { item.state = checked ? .on : .off }
            (parent ?? menu).addItem(item)
        }
        func submenu(_ title: String) -> NSMenu {
            let child = NSMenu(); child.autoenablesItems = false
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = child; menu.addItem(item)
            return child
        }
        add("AirKey 0.3.4 · \(camera.status)")
        add(output.status)
        if output.needsPermission { add("Already enabled? Re-add this copy in System Settings.") }
        if !keyboard.message.isEmpty { add(keyboard.message) }
        menu.addItem(.separator())
        add("Show keyboard", "show")
        add("Tuck into corner / pause camera", "tuck")
        add("Hide keyboard / pause camera", "hide")
        add(output.needsPermission ? "Enable typing into apps…" : "Accessibility settings…", "permission")
        add("Reveal this app in Finder", "revealApp")
        menu.addItem(.separator())
        let language = submenu("Language")
        for value in TypingLanguage.allCases { add(value.title, "language:\(value.rawValue)", checked: keyboard.language == value, enabled: keyboard.benchmark == nil, to: language) }
        let pinch = submenu("Pinch effort")
        for (title, threshold) in [("Light", 0.50), ("Standard", 0.40), ("Firm", 0.30)] {
            add(title, "pinch:\(threshold)", checked: camera.pinchThreshold == threshold, enabled: keyboard.benchmark == nil, to: pinch)
        }
        add("Swipe typing", "swipe", checked: keyboard.swipeMode, enabled: keyboard.benchmark == nil)
        let appearance = submenu("Appearance")
        add("Hand hologram", "hologram", checked: camera.cameraGhostEnabled, to: appearance)
        add("Pinch cursors", "cursors", checked: keyboard.showPointers, to: appearance)
        let hiding = submenu("Automatic hiding")
        add("Fully transparent after 8 seconds idle", "fade", checked: visibility.fadeEnabled, to: hiding)
        add("Tuck after 45 seconds idle", "autoTuck", checked: visibility.tuckEnabled, to: hiding)
        add("Tuck in full screen", "fullScreen", checked: visibility.fullScreenEnabled, to: hiding)
        add("Restore with an open-hand movement, the tab, or this menu", to: hiding)
        menu.addItem(.separator())
        add("Typing test…", "practice", enabled: !keyboard.isDecoding)
        add("Undo", "undo", enabled: keyboard.canUndo)
        add("Accidental pinch", "accidental", enabled: keyboard.canCorrectAccidentalPinch)
        let learning = submenu("Learning and protection")
        add("Resting-hand protection", "protection", checked: keyboard.restingHandProtection, enabled: keyboard.benchmark == nil, to: learning)
        add("Personal learning", "learning", checked: keyboard.profile.enabled, enabled: keyboard.benchmark == nil, to: learning)
        add("Learn current word", "learnWord", enabled: keyboard.canLearnCurrentWord, to: learning)
        add("Reset personal learning", "resetLearning", enabled: keyboard.benchmark == nil, to: learning)
        add("Copy tracking report", "report")
        add(camera.isRunning ? "Stop camera" : "Start / retry camera", "camera")
        menu.addItem(.separator())
        add("Quit AirKey", "quit")
    }

    @objc private func performMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        activity()
        if command.hasPrefix("language:"), let language = TypingLanguage(rawValue: String(command.dropFirst(9))) { keyboard.language = language; return }
        if command.hasPrefix("pinch:"), let threshold = Double(command.dropFirst(6)) { keyboard.cancelInput(); camera.setPinchThreshold(threshold); return }
        switch command {
        case "show": showKeyboard()
        case "tuck": tuckKeyboard()
        case "hide": hideKeyboard()
        case "permission": output.requestPermission()
        case "revealApp": NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        case "swipe": keyboard.swipeMode.toggle()
        case "hologram": camera.setCameraGhostEnabled(!camera.cameraGhostEnabled)
        case "cursors": keyboard.showPointers.toggle()
        case "fade": visibility.fadeEnabled.toggle(); save("fade", visibility.fadeEnabled)
        case "autoTuck": visibility.tuckEnabled.toggle(); save("tuck", visibility.tuckEnabled)
        case "fullScreen": visibility.fullScreenEnabled.toggle(); save("fullScreen", visibility.fullScreenEnabled)
        case "practice": showPractice()
        case "undo": keyboard.undo()
        case "accidental": keyboard.correctAccidentalPinch()
        case "protection": keyboard.restingHandProtection.toggle()
        case "learning": keyboard.setLearningEnabled(!keyboard.profile.enabled)
        case "learnWord": keyboard.learnCurrentWord()
        case "resetLearning": keyboard.resetLearning()
        case "report": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(camera.trackingReport, forType: .string)
        case "camera":
            keyboard.cancelInput()
            if camera.isRunning { camera.stop() } else { showKeyboard(); camera.stop(); camera.start() }
        case "quit": quit()
        default: break
        }
    }

    private func showPractice() {
        showKeyboard()
        keyboard.startBenchmark(pinchThreshold: camera.pinchThreshold)
        if practice == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AirKey typing test"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: PracticeView(keyboard: keyboard, camera: camera).padding(16).preferredColorScheme(.dark))
            window.center(); practice = window
        }
        practice?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === practice { keyboard.cancelBenchmark(); keyboard.dismissBenchmarkResult(); output.reset(); return true }
        hideKeyboard(); return false
    }
    func windowDidMove(_ notification: Notification) {
        if let moved = notification.object as? NSWindow, moved === panel, visibility.state == .visible || visibility.state == .faded {
            restoreFrame = moved.frame; activity()
        }
    }
    @objc private func sleep() { hideKeyboard() }
    @objc private func quit() { idleTask?.cancel(); camera.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { persistPlacement(); idleTask?.cancel(); camera.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showKeyboard(); return true }
}
