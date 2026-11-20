import AppKit
import Sparkle
import SightlineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private var displays: DisplayRegistry!
    private var driver: WindowDriver!
    private var snaps: SnapController!
    private var hotKeys: HotKeyCenter!
    private var hud: HUD!
    private var dragSnap: DragSnap!
    private var quickMenu: QuickMenu!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem?
    /// Owns the update check, the appcast fetch and the install/relaunch cycle.
    private var updater: SPUStandardUpdaterController!
    /// Windows that were on screen when the self-test started, and where they were.
    private var selfTestBystanders: [(window: AXWindow, frame: CGRect)] = []

    /// Watches the usable area so a Dock that moves or resizes is followed.
    private var usableWatch: Timer?
    private var usableDebounce: Timer?
    private var lastUsableSignature = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs.load()
        displays = DisplayRegistry(prefs: prefs)
        driver = WindowDriver()
        snaps = SnapController(driver: driver, displays: displays, prefs: prefs)
        hud = HUD()
        dragSnap = DragSnap(driver: driver, displays: displays, snaps: snaps, prefs: prefs)
        quickMenu = QuickMenu(prefs: prefs) { [weak self] action in
            self?.handle(action)
        }
        quickMenu.desktopTakeover = prefs.quickMenuOnDesktopRightClick
        if ProcessInfo.processInfo.environment["SIGHTLINE_VERBOSE"] != nil {
            dragSnap.log = { [weak self] line in self?.log(line) }
            quickMenu.log = { [weak self] line in self?.log(line) }
        }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Test hook: an explicit check on launch, so the update path can be
        // exercised without hunting for the menu item.
        if ProcessInfo.processInfo.environment["SIGHTLINE_CHECK_UPDATES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.log("updates: explicit check")
                self?.updater.checkForUpdates(nil)
            }
        }
        settings = SettingsWindowController(prefs: prefs, displays: displays) { [weak self] in
            guard let self else { return }
            self.snaps.arrangeAll()
        }

        snaps.onStatus = { [weak self] text, rect in
            guard let self else { return }
            self.log("status: \(text)")
            let anchor = rect ?? self.displays.primary?.usableFrame ?? .zero
            self.hud.show(text, on: anchor)
        }

        buildMainMenu()
        installStatusItem()

        hotKeys = HotKeyCenter()
        hotKeys.onAction = { [weak self] action in self?.handle(action) }
        hotKeys.install()
        if prefs.dragSnapEnabled { dragSnap.install() }
        if prefs.quickMenuEnabled { quickMenu.install() }

        prefs.onChange = { [weak self] changedDisplay in
            self?.preferencesChanged(changedDisplay)
        }

        startUsableAreaWatch()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged()
            }
        }

        if !Accessibility.isTrusted {
            Accessibility.requestPrompt()
        }
        let environment = ProcessInfo.processInfo.environment
        let forceShow = environment["SIGHTLINE_SNAPSHOT"] != nil || environment["SIGHTLINE_SELFTEST"] != nil
        if !prefs.hasSeenOnboarding || !Accessibility.isTrusted || forceShow {
            prefs.hasSeenOnboarding = true
            settings.show()
        }

        settings.setUnavailableShortcuts(hotKeys.failures)

        if environment["SIGHTLINE_VERBOSE"] != nil {
            let trust = Accessibility.isTrusted ? "trusted" : "NOT trusted"
            FileHandle.standardError.write(Data("Sightline: accessibility \(trust)\n".utf8))
            let failed = hotKeys.failures.map { "\($0.shortcut) \($0.title)" }
            FileHandle.standardError.write(Data("Sightline: hotkeys failed=\(failed)\n".utf8))
            for screen in displays.screens {
                let layout = prefs.layout(for: screen.id)
                let geo = screen.geometry(layout)
                let center = geo.rect(for: .center) ?? .zero
                FileHandle.standardError.write(Data(
                    "Sightline: \(screen.name) frame=\(screen.frame) usable=\(screen.usableFrame) centre=\(center) fraction=\(layout.centerFraction)\n".utf8
                ))
            }
        }

        // Renders the settings window to a PNG without needing Screen Recording.
        // Used for automated visual verification: SIGHTLINE_SNAPSHOT=/path.png
        if let path = environment["SIGHTLINE_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.captureSnapshot(to: path)
            }
        }

        // Drives our own settings window through every slot with real AX calls,
        // then fires a synthetic hotkey. Touches no other app's windows.
        if environment["SIGHTLINE_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runSelfTest()
            }
        }
    }

    // MARK: - Self test

    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func postHotKey(virtualKey: CGKeyCode,
                            flags: CGEventFlags = [.maskControl, .maskAlternate]) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func runSelfTest() {
        guard let screen = displays.primary else {
            log("selftest: no display"); self.finishSelfTest(2)
        }
        let geo = screen.geometry(prefs.layout(for: screen.id))

        // Plain windows with no min size, so a failure means our AX code failed
        // and not that the window refused to shrink.
        let windowA = scratchWindow(title: "Self Test A")
        let windowB = scratchWindow(title: "Self Test B")
        guard let a = driver.windows(ofApp: getpid()).first(where: { $0.key.title == "Self Test A" }),
              let b = driver.windows(ofApp: getpid()).first(where: { $0.key.title == "Self Test B" })
        else {
            log("selftest: scratch windows missing from AX"); self.finishSelfTest(3)
        }
        _ = windowB

        // The test drives real boards, and the permutation rule can push a real
        // window out of the way to make room. Remember where everything was and put
        // it back, so running the self-test never rearranges the user's desktop.
        selfTestBystanders = driver.allWindows()
            .filter { $0.key.pid != getpid() }
            .compactMap { window in driver.frame(of: window.element).map { (window, $0) } }

        var failures = 0

        for slot in Slot.allCases {
            guard let rect = geo.rect(for: slot) else { continue }
            let applied = driver.setFrame(rect, of: a.element)
            let actual = driver.frame(of: a.element) ?? .zero
            let match = WindowDriver.matches(actual, rect, tolerance: 2)
            if !match { failures += 1 }
            log("selftest \(slot.label) set=\(applied) want=\(rect.integral) got=\(actual.integral) \(match ? "PASS" : "FAIL")")
        }

        // Permutation: B takes the centre from A, and A lands in B's old slot.
        guard let leftTop = geo.rect(for: .leftTop), let center = geo.rect(for: .center) else {
            log("selftest: geometry missing"); self.finishSelfTest(4)
        }
        _ = snaps.perform(window: a, slot: .center, screen: screen)
        _ = snaps.perform(window: b, slot: .leftTop, screen: screen)
        _ = snaps.perform(window: b, slot: .center, screen: screen)
        let aFrame = driver.frame(of: a.element) ?? .zero
        let bFrame = driver.frame(of: b.element) ?? .zero
        let swapOK = WindowDriver.matches(aFrame, leftTop, tolerance: 2)
            && WindowDriver.matches(bFrame, center, tolerance: 2)
        if !swapOK { failures += 1 }
        log("selftest swap a=\(aFrame.integral) b=\(bFrame.integral) \(swapOK ? "PASS" : "FAIL")")

        // Hotkey: A is put on the left pane and made key, then ⌃⌥1 should bring
        // the focused window — A — to the centre board.
        _ = driver.setFrame(leftTop, of: a.element)
        NSApp.activate(ignoringOtherApps: true)
        windowA.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.postHotKey(virtualKey: 18)  // kVK_ANSI_1 — "place in the centre board"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { exit(5) }
            let actual = self.driver.frame(of: a.element) ?? .zero
            let ok = WindowDriver.matches(actual, center, tolerance: 2)
            if !ok { failures += 1 }
            self.log("selftest hotkey ⌃⌥1 got=\(actual.integral) want=\(center.integral) \(ok ? "PASS" : "FAIL")")

            // Hop: from the centre, ⌃⌥← should land in the left column. This also
            // proves the arrow shortcuts win over any other app that uses them.
            windowA.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.postHotKey(virtualKey: 4,
                                flags: [.maskControl, .maskAlternate, .maskShift])  // ⌃⌥⇧H
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { exit(6) }
                let frame = self.driver.frame(of: a.element) ?? .zero
                let expected = [geo.rect(for: .leftTop), geo.rect(for: .leftBottom)].compactMap { $0 }
                let hopOK = expected.contains { WindowDriver.matches(frame, $0, tolerance: 2) }
                if !hopOK { failures += 1 }
                self.log("selftest hop ⌃⌥⇧H got=\(frame.integral) \(hopOK ? "PASS" : "FAIL")")

                // Drag: ⌥-drag A from the left column onto the right column's lower
                // pane. AppKit's own window-drag tracking loop reads events directly
                // and never reaches a local monitor, so the pipeline is driven through
                // the same entry point the monitor uses.
                self.dragSnap.allowsOwnWindows = true
                let rightBottom = geo.rect(for: .rightBottom) ?? .zero
                windowA.makeKeyAndOrderFront(nil)
                self.dragSnap.debugDrag(
                    window: a,
                    from: CGPoint(x: leftTop.midX, y: leftTop.minY + 14),
                    to: CGPoint(x: rightBottom.midX, y: rightBottom.midY)
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let self else { exit(7) }
                    let dragged = self.driver.frame(of: a.element) ?? .zero
                    let dragOK = WindowDriver.matches(dragged, rightBottom, tolerance: 2)
                    if !dragOK { failures += 1 }
                    self.log("selftest drag ⌥→RB got=\(dragged.integral) want=\(rightBottom.integral) \(dragOK ? "PASS" : "FAIL")")
                    self.dragSnap.allowsOwnWindows = false

                    // Drag swap: A sits tracked in the centre, B is parked in LT
                    // without being tracked (as a freshly dragged window would be).
                    // Dragging B onto the centre must send A to LT, not to B's old
                    // floating frame.
                    _ = self.snaps.perform(window: a, slot: .center, screen: screen)
                    if let lt = geo.rect(for: .leftTop) {
                        _ = self.driver.setFrame(lt, of: b.element)
                    }
                    let centre = geo.rect(for: .center) ?? .zero
                    let bStart = self.driver.frame(of: b.element) ?? .zero
                    self.dragSnap.allowsOwnWindows = true
                    windowB.makeKeyAndOrderFront(nil)
                    self.dragSnap.debugDrag(
                        window: b,
                        from: CGPoint(x: bStart.midX, y: bStart.minY + 14),
                        to: CGPoint(x: centre.midX, y: centre.midY)
                    )

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { exit(8) }
                        let aFrame = self.driver.frame(of: a.element) ?? .zero
                        let bFrame = self.driver.frame(of: b.element) ?? .zero
                        let wantLeftTop = geo.rect(for: .leftTop) ?? .zero
                        let swapOK = WindowDriver.matches(aFrame, wantLeftTop, tolerance: 2)
                            && WindowDriver.matches(bFrame, centre, tolerance: 2)
                        if !swapOK { failures += 1 }
                        self.log("selftest drag-swap a→LT b→C got a=\(aFrame.integral) b=\(bFrame.integral) want a=\(wantLeftTop.integral) b=\(centre.integral) \(swapOK ? "PASS" : "FAIL")")
                        self.dragSnap.allowsOwnWindows = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.log("selftest: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
                            self.prefs.save()
                            self.finishSelfTest(failures == 0 ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    /// Restore the user's windows, then exit. `exit()` skips `defer`, and the test
    /// ends inside async closures, so every exit point goes through here.
    private func finishSelfTest(_ code: Int32) -> Never {
        for (window, frame) in selfTestBystanders {
            _ = driver.setFrame(frame, of: window.element)
        }
        exit(code)
    }

    private func scratchWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 520, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title

        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func captureSnapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.title == "Sightline" }),
              let view = window.contentView else {
            FileHandle.standardError.write(Data("snapshot: window not found\n".utf8))
            NSApp.terminate(nil)
            return
        }
        // The docs shot wants the whole proportions card, including the
        // quick-menu toggles, so give the window a tall frame before the cache.
        // Aqua keeps the documentation image identical regardless of the
        // machine's current appearance.
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 900, height: 1306))
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            FileHandle.standardError.write(Data("snapshot: no bitmap rep\n".utf8))
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: encoding failed\n".utf8))
            NSApp.terminate(nil)
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data(
                "snapshot: wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        prefs.save()
        hotKeys?.uninstall()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Reactions

    private func preferencesChanged(_ changedDisplay: String?) {
        if prefs.dragSnapEnabled { dragSnap.install() } else { dragSnap.uninstall() }
        if prefs.quickMenuEnabled { quickMenu.install() } else { quickMenu.uninstall() }
        quickMenu.desktopTakeover = prefs.quickMenuOnDesktopRightClick
        displays.refresh()
        snaps.reflow()
        settings.reload()
    }

    private func screenParametersChanged() {
        applyUsableArea(log: "displays changed")
        // The visible frame of a screen can still be the old one when the
        // notification arrives, so look again once the change has settled.
        scheduleUsableAreaCheck()
    }

    // MARK: - Dock and usable area tracking

    /// `NSScreen.visibleFrame` shrinks when the Dock sits at the bottom, on the
    /// left or on the right, and it grows when the Dock is hidden or resized.
    /// AppKit announces a Dock move with `didChangeScreenParametersNotification`,
    /// but not every resize reaches us reliably (and the notification can arrive
    /// one frame early), so compare the live usable area on a slow timer as well.
    private func startUsableAreaWatch() {
        lastUsableSignature = displays.signature
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkUsableArea()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usableWatch = timer
    }

    private func checkUsableArea() {
        guard displays.liveSignature != lastUsableSignature else { return }
        scheduleUsableAreaCheck()
    }

    /// Debounced: a Dock that is sliding in and out (auto-hide) or a display that
    /// is still reconfiguring should settle before windows are re-flowed.
    private func scheduleUsableAreaCheck() {
        usableDebounce?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.displays.liveSignature != self.lastUsableSignature else { return }
                self.applyUsableArea(log: "usable area changed")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usableDebounce = timer
    }

    private func applyUsableArea(log reason: String) {
        lastUsableSignature = displays.liveSignature
        displays.refresh()
        log("\(reason): usable \(displays.signature)")
        snaps.reflow()
        settings.reload()
    }

    private func handle(_ action: HotKeyAction) {
        log("hotkey: \(action)")
        if action != .openSettings && !Accessibility.isTrusted {
            Accessibility.requestPrompt()
            settings.show()
            return
        }

        switch action {
        case .placeCenter: snaps.placeFocused(in: .center)
        case .placeLeftTop: snaps.placeFocused(in: .leftTop)
        case .placeLeftBottom: snaps.placeFocused(in: .leftBottom)
        case .placeRightTop: snaps.placeFocused(in: .rightTop)
        case .placeRightBottom: snaps.placeFocused(in: .rightBottom)
        case .hopLeft: snaps.hop(.left)
        case .hopRight: snaps.hop(.right)
        case .hopUp: snaps.hop(.up)
        case .hopDown: snaps.hop(.down)
        case .cycleForward: snaps.cycleStage()
        case .cycleBackward: snaps.cycleStage(backwards: true)
        case .stageFocused: snaps.stageFocusedWindow()
        case .toggleSplit: snaps.toggleSplit()
        case .presetPrevious: snaps.stepPreset(-1)
        case .presetNext: snaps.stepPreset(1)
        case .nudgeNarrower: snaps.nudgeCenter(-1)
        case .nudgeWider: snaps.nudgeCenter(1)
        case .fillScreen: snaps.fillScreen()
        case .arrangeAll: snaps.arrangeAll()
        case .centerWindow: snaps.centerAtCurrentSize()
        case .saveArrangement: snaps.saveArrangement()
        case .restoreArrangement: snaps.restoreArrangement()
        case .openSettings: settings.show()
        }
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sightline", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sightline", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Sightline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Sightline")
                ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Sightline")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Sightline"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        settings.refreshTrust()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        var header = NSAttributedString(
            string: "Sightline",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        )
        if let screen = displays.primary {
            let sub = NSAttributedString(
                string: "\n\(screen.name) · \(Int(screen.physicalWidthCM.rounded())) cm",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            let combined = NSMutableAttributedString(attributedString: header)
            combined.append(sub)
            header = combined
        }
        let headerItem = NSMenuItem()
        headerItem.attributedTitle = header
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if !Accessibility.isTrusted {
            menu.addItem(.separator())
            let grant = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(grantAccessibility),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(.arrangeAll))
        let forget = NSMenuItem(
            title: "Forget app-to-board memory",
            action: #selector(forgetBoardMemory),
            keyEquivalent: ""
        )
        forget.target = self
        forget.isEnabled = prefs.hasBoardMemory
        forget.toolTip = "Arrange remembers which board each app used. This clears that memory."
        menu.addItem(forget)
        menu.addItem(.separator())

        let place = NSMenu()
        for action in [HotKeyAction.placeCenter, .placeLeftTop, .placeLeftBottom, .placeRightTop, .placeRightBottom] {
            place.addItem(actionItem(action))
        }
        menu.addItem(submenuItem("Place window", place))

        let move = NSMenu()
        for action in [HotKeyAction.hopLeft, .hopRight, .hopUp, .hopDown] {
            move.addItem(actionItem(action))
        }
        menu.addItem(submenuItem("Move window", move))

        let stage = NSMenu()
        stage.addItem(actionItem(.stageFocused))
        stage.addItem(actionItem(.cycleForward))
        stage.addItem(actionItem(.cycleBackward))
        stage.addItem(.separator())
        let clear = NSMenuItem(title: "Clear stage", action: #selector(clearStage), keyEquivalent: "")
        clear.target = self
        stage.addItem(clear)
        menu.addItem(submenuItem("Centre stage", stage))

        menu.addItem(.separator())

        let current = currentLayout()
        let layoutMenu = NSMenu()
        for preset in LayoutPreset.all {
            let item = NSMenuItem(
                title: "\(preset.name) · \(Int((preset.centerFraction * 100).rounded()))%",
                action: #selector(applyPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id
            item.toolTip = preset.blurb
            if abs(preset.centerFraction - current.centerFraction) < 0.005 {
                item.state = .on
            }
            layoutMenu.addItem(item)
        }
        layoutMenu.addItem(.separator())
        layoutMenu.addItem(actionItem(.nudgeNarrower))
        layoutMenu.addItem(actionItem(.nudgeWider))
        layoutMenu.addItem(.separator())
        let split = NSMenuItem(title: "Split side boards", action: #selector(toggleSplit), keyEquivalent: "")
        split.target = self
        split.state = current.splitSides ? .on : .off
        layoutMenu.addItem(split)
        let dragItem = NSMenuItem(title: "Snap by dragging (⌥-drag)", action: #selector(toggleDragSnap), keyEquivalent: "")
        dragItem.target = self
        dragItem.state = prefs.dragSnapEnabled ? .on : .off
        layoutMenu.addItem(dragItem)
        let quickItem = NSMenuItem(title: "Quick menu on ⌥-right-click", action: #selector(toggleQuickMenu), keyEquivalent: "")
        quickItem.target = self
        quickItem.state = prefs.quickMenuEnabled ? .on : .off
        layoutMenu.addItem(quickItem)
        layoutMenu.addItem(.separator())
        layoutMenu.addItem(actionItem(.fillScreen))
        layoutMenu.addItem(actionItem(.centerWindow))
        menu.addItem(submenuItem("Layout", layoutMenu))

        let arrangement = NSMenu()
        arrangement.addItem(actionItem(.saveArrangement))
        arrangement.addItem(actionItem(.restoreArrangement))
        arrangement.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal arrangement file", action: #selector(revealArrangement), keyEquivalent: "")
        reveal.target = self
        arrangement.addItem(reveal)
        menu.addItem(submenuItem("Arrangements", arrangement))

        menu.addItem(.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sightline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func currentLayout() -> ScreenLayout {
        guard let screen = displays.primary else { return prefs.defaultLayout }
        return prefs.layout(for: screen.id)
    }

    private func actionItem(_ action: HotKeyAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Int(action.rawValue)
        item.attributedTitle = attributedTitle(action.title, shortcut: action.shortcut)
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func attributedTitle(_ title: String, shortcut: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 268)]
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        guard !shortcut.isEmpty else { return result }
        result.append(NSAttributedString(
            string: "\t\(shortcut)",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return result
    }

    // MARK: - Menu actions

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let action = HotKeyAction(rawValue: UInt32(sender.tag)) else { return }
        handle(action)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let preset = LayoutPreset.all.first(where: { $0.id == id }),
              let screen = displays.primary else { return }
        snaps.apply(preset: preset, to: screen)
    }

    @objc private func toggleSplit() {
        snaps.toggleSplit()
    }

    @objc private func toggleDragSnap() {
        prefs.dragSnapEnabled.toggle()
        if prefs.dragSnapEnabled { dragSnap.install() } else { dragSnap.uninstall() }
        settings.reload()
    }

    @objc private func toggleQuickMenu() {
        prefs.quickMenuEnabled.toggle()
        if prefs.quickMenuEnabled { quickMenu.install() } else { quickMenu.uninstall() }
        settings.reload()
    }

    @objc private func clearStage() {
        snaps.clearStage()
    }

    @objc private func forgetBoardMemory() {
        prefs.forgetBoardMemory()
        hud.show("Board memory cleared", on: displays.primary?.usableFrame ?? .zero)
    }

    @objc private func revealArrangement() {
        snaps.revealArrangementFile()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func grantAccessibility() {
        Accessibility.requestPrompt()
        Accessibility.openSystemSettings()
        settings.show()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Sightline",
            .applicationVersion: "0.1",
            .credits: NSAttributedString(
                string: "Attention-weighted window boards for a wide display.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
