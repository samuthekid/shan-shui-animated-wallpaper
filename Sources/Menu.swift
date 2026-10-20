import AppKit

// The menu of the status item, and what its items do besides pause, speed and density (those are in main.swift).

extension Wallpaper {
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
            // Copy the picture out of the app first, so it survives a rebuild, move or delete of the app.
            // One copy for every Space (each Space is applied separately), so we never delete it.
            // ponytail: if a future version ships a different picture, change this file name.
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ShanShui")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent("background-4k.jpg")
            if !fm.fileExists(atPath: copy.path) { try fm.copyItem(at: url, to: copy) }
            for s in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(copy, for: s, options: [:]) }
        } catch {
            say("The desktop picture could not be changed.", error.localizedDescription)
        }
    }

    func open(_ url: String) { NSWorkspace.shared.open(URL(string: url)!) }

    @objc func showPrivacy() { open("https://samuapps.dev/shan-shui/privacy.html") }

    @objc func showGitHub() { open("https://github.com/samuthekid/shan-shui-animated-wallpaper") }

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
}
