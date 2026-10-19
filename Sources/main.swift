import AppKit

// The app: menu bar item, settings, one landscape per screen, and the launch.

// Defaults are registered at launch (see applicationDidFinishLaunching). double(forKey:) also reads the string of a
// launch argument like "-speed 30". The value is clamped to the slider range.
// The ranges of the two sliders are here (the top speed, K.maxSpeed, is in Render.swift: the lead uses it).
enum Settings {
    static let minSpeed = 2.0
    static let minDensity = 0.2  // 1 = upstream look
    static let maxDensity = 2.0

    static var speed: Double {  // screen points per second
        get { min(max(UserDefaults.standard.double(forKey: "speed"), minSpeed), K.maxSpeed) }
        set { UserDefaults.standard.set(newValue, forKey: "speed") }
    }
    static var density: Double {
        get { min(max(UserDefaults.standard.double(forKey: "density"), minDensity), maxDensity) }
        set { UserDefaults.standard.set(newValue, forKey: "density") }
    }
}

func displayID(_ s: NSScreen) -> UInt32 {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

@MainActor
final class Wallpaper: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let exportTag = 9001  // marks the Export Frame item of the menu (Export.swift)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let engine = Engine()
    var landscapes: [UInt32: Landscape] = [:]  // by display ID (in test mode: by window number)
    var nextWorld = 0
    var syncTimer: Timer?
    var paused = false  // not saved: the app always starts running
    var sweepStep = 0  // for --sweep (Debug.swift)
    let launched = Date()

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["speed": 15.0, "density": 1.0])
        NSApp.setActivationPolicy(.accessory)
        item.button?.title = "山水"
        item.menu = makeMenu()
        engine.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(showError(_:)), name: .generatorFailed, object: nil)
        if Opt.window {
            #if !STORE
            makeTestWindows()
            #endif
        } else {
            NotificationCenter.default.addObserver(
                self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            syncScreens()
        }
        if let s = Opt.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) }
        }
        #if !STORE
        if let dir = Opt.debug { startDebug(dir) }
        if Opt.sweep { startSweep() }
        #endif
    }

    // The generator did not start: a disabled line at the top of the menu says why.
    @objc func showError(_ n: Notification) {
        let reason = (n.userInfo?["reason"] as? String) ?? "unknown"
        let title = "Error: " + String(reason.prefix(80))
        if let e = item.menu?.item(at: 0), e.title.hasPrefix("Error: ") {
            e.title = title
            return
        }
        let e = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        e.isEnabled = false
        item.menu?.insertItem(e, at: 0)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self  // menuNeedsUpdate fills the Export Frame item (Export.swift)
        menu.addItem(withTitle: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "").target = self
        menu.addItem(sliderItem("Speed", Settings.minSpeed, K.maxSpeed, Settings.speed, #selector(speedChanged(_:))))
        menu.addItem(sliderItem("Density", Settings.minDensity, Settings.maxDensity, Settings.density, #selector(densityChanged(_:))))
        menu.addItem(NSMenuItem.separator())
        let export = menu.addItem(withTitle: "Export Frame", action: nil, keyEquivalent: "")
        export.tag = Wallpaper.exportTag
        export.isHidden = true
        let more = NSMenu()
        more.addItem(withTitle: "Apply App Background…", action: #selector(applyBackground), keyEquivalent: "").target = self
        more.addItem(withTitle: "GitHub", action: #selector(showGitHub), keyEquivalent: "").target = self
        more.addItem(withTitle: "Privacy Policy", action: #selector(showPrivacy), keyEquivalent: "").target = self
        more.addItem(withTitle: "About Shan Shui Animated Wallpaper", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "More", action: nil, keyEquivalent: "").submenu = more
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        return menu
    }

    // Pause stops the pan, the timer and the engine work of every screen (Landscape.setRunning). The frame stays.
    // Resume goes on from the same place. A new screen while paused is drawn once, then stops.
    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.title = paused ? "Resume" : "Pause"
        landscapes.values.forEach { $0.paused = paused; $0.visibilityChanged() }
    }

    // The only place where the app changes the desktop picture, and only after the user presses This Space.
    @objc func applyBackground() {
        NSApp.activate(ignoringOtherApps: true)
        func say(_ title: String, _ text: String) {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.runModal()
        }
        guard let url = Bundle.main.url(forResource: "background-4k", withExtension: "jpg") else {
            return say("The picture is missing.", "This copy of the app has no background picture.")
        }
        let alert = NSAlert()
        alert.messageText = "Match Mission Control?"
        alert.informativeText = """
            Mission Control and the Spaces bar can't show the moving landscape. They show your desktop picture instead.

            Tap "This Space" to set a plain paper picture that matches the landscape. It only changes this Space. \
            To use it everywhere, choose "Show on all Spaces" in System Settings > Wallpaper.
            """
        alert.addButton(withTitle: "Cancel")  // the first button is the default
        alert.addButton(withTitle: "This Space")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            for s in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [:]) }
        } catch {
            say("The desktop picture could not be changed.", error.localizedDescription)
        }
    }

    @objc func showPrivacy() {
        NSWorkspace.shared.open(URL(string: "https://samuapps.dev/shan-shui/privacy.html")!)
    }

    @objc func showGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/samuthekid/shan-shui-animated-wallpaper")!)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = """
            Landscape generator: shan-shui-inf by Lingdong Huang, MIT License.
            https://github.com/LingDong-/shan-shui-inf

            """
        let license = Bundle.main.url(forResource: "LICENSE-shan-shui-inf", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let text = NSMutableAttributedString(
            string: credits + license, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        text.addAttribute(.link, value: "https://github.com/LingDong-/shan-shui-inf",
                          range: (text.string as NSString).range(of: "https://github.com/LingDong-/shan-shui-inf"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
    }

    func sliderItem(_ title: String, _ lo: Double, _ hi: Double, _ value: Double, _ action: Selector) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 14, y: 24, width: 172, height: 16)
        let slider = NSSlider(value: value, minValue: lo, maxValue: hi, target: self, action: action)
        slider.frame = NSRect(x: 14, y: 4, width: 172, height: 20)
        // The menu is as wide as its longest item. The row and the slider follow that width.
        view.autoresizingMask = .width
        label.autoresizingMask = .width
        slider.autoresizingMask = .width
        view.addSubview(label)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc func speedChanged(_ s: NSSlider) { applySpeed(s.doubleValue) }
    @objc func densityChanged(_ s: NSSlider) { applyDensity(s.doubleValue) }

    // The sliders and --sweep use these two. They apply to all screens.
    func applySpeed(_ v: Double) {
        Settings.speed = v
        landscapes.values.forEach { $0.repan(speed: v) }  // at once, without a jump. The lead does not depend on the speed.
    }

    func applyDensity(_ d: Double) {
        Settings.density = d  // new chunks only: tiles that are drawn stay
        landscapes.values.forEach { $0.engine.setDensity(id: $0.id, d) }
    }

    // The screen setup changed. The notification comes several times in a row: wait until it is quiet.
    @objc func screensChanged() {
        syncTimer?.invalidate()
        syncTimer = commonTimer(0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncScreens() }
        }
    }

    // One landscape per screen, found by display ID.
    //  - same ID, frame and scale: nothing happens, the landscape keeps running
    //  - another frame or scale: a new landscape (a new world). The old one stays on the screen until the new one is
    //    ready and has faded in (see Landscape.checkReady), then the old one closes
    //  - a new screen: a new landscape
    //  - a screen that is gone: its landscape stops
    //  Windows made while the app is .regular are drawn live in Space swipes and Mission Control. Windows made
    //  while it is .accessory are not (they show the static desktop picture). So the app is .regular, briefly,
    //  while the windows are made. The Dock icon shows for that time only.
    func syncScreens() {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.setActivationPolicy(.accessory) }
        var seen = Set<UInt32>()
        for screen in NSScreen.screens {
            let key = displayID(screen)
            seen.insert(key)
            let cur = landscapes[key]
            if let cur = cur, cur.screenFrame == screen.frame, cur.backing == screen.backingScaleFactor { continue }
            var old: Landscape? = nil
            if let cur = cur {
                // if cur is not shown yet, the one on the screen is the one that cur would replace
                old = cur.started ? cur : cur.replaced
                cur.replaced = nil
                if !cur.started { cur.stop() }
            }
            let land = makeLandscape(screen)
            land.replaced = old
            landscapes[key] = land
        }
        for (key, land) in landscapes where !seen.contains(key) {
            land.stop()
            landscapes[key] = nil
        }
    }

    // One borderless, click-through, desktop-level window. Desktop icons stay above it.
    // It is shown later by the landscape, when the first screen is ready.
    func makeLandscape(_ screen: NSScreen) -> Landscape {
        let win = Landscape.makeWindow(frame: screen.frame, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))),
                                       wallpaper: true)
        nextWorld += 1
        let land = Landscape(engine: engine, id: nextWorld, window: win, size: screen.frame.size, scale: screen.backingScaleFactor,
                             frame: screen.frame, speed: Settings.speed, density: Settings.density)
        win.setFrame(screen.frame, display: false)
        return land
    }
}

#if !STORE
if let path = Opt.still { MainActor.assumeIsolated { renderStill(path) } }  // never returns
#endif
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Wallpaper()
    app.delegate = delegate
    app.run()
}
