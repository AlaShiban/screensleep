import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dimmer = Dimmer()
    private let prefs = Preferences.shared

    private let intervalChoices: [Double] = [1, 2, 5, 10, 15, 30, 45, 60]
    private let targetChoices: [(String, Double)] = [
        ("Black (0%)", 0), ("Very dark (5%)", 0.05), ("Dark (10%)", 0.10), ("Dim (20%)", 0.20),
    ]
    private let undimChoices: [(String, Double)] = [
        ("25%", 0.25), ("50%", 0.50), ("75%", 0.75), ("100%", 1.0),
    ]
    private let fadeChoices: [(String, Double)] = [
        ("Instant", 0), ("1 second", 1), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BrightnessAPI.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "Can't control display brightness"
            alert.informativeText = "ScreenSleep couldn't load the system brightness interface on this version of macOS."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self
        updateIcon(for: dimmer.state)

        dimmer.onStateChange = { [weak self] state in self?.updateIcon(for: state) }
        dimmer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dimmer.restore()
        dimmer.stop()
    }

    // MARK: - Menu bar icon

    private func updateIcon(for state: Dimmer.State) {
        guard let button = statusItem.button else { return }
        let name: String
        if !prefs.enabled {
            name = "sun.max.trianglebadge.exclamationmark"
        } else if state == .idleWatching {
            name = "sun.max"
        } else {
            name = "moon.zzz.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ScreenSleep")
        image?.isTemplate = true
        button.image = image
        button.toolTip = prefs.enabled
            ? "Auto Dimmer on — dims after \(formatMinutes(prefs.idleMinutes)) idle"
            : "Auto Dimmer off"
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 100
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("Auto Dimmer", #selector(toggleEnabled), tag: 101))
        menu.addItem(item("Dim Now", #selector(dimNow), tag: 102))
        menu.addItem(item("Undim", #selector(undimNow), tag: 108))
        menu.addItem(.separator())

        let interval = NSMenu()
        for minutes in intervalChoices {
            let mi = item(formatMinutes(minutes), #selector(setInterval))
            mi.representedObject = minutes
            interval.addItem(mi)
        }
        interval.addItem(.separator())
        interval.addItem(item("Custom…", #selector(setCustomInterval)))
        menu.addItem(submenu("Dim After", interval, tag: 103))

        let target = NSMenu()
        for (title, value) in targetChoices {
            let mi = item(title, #selector(setTarget))
            mi.representedObject = value
            target.addItem(mi)
        }
        menu.addItem(submenu("Dim To", target, tag: 104))

        let undim = NSMenu()
        for (title, value) in undimChoices {
            let mi = item(title, #selector(setUndimTarget))
            mi.representedObject = value
            undim.addItem(mi)
        }
        menu.addItem(submenu("Undim To", undim, tag: 109))

        let fade = NSMenu()
        for (title, value) in fadeChoices {
            let mi = item(title, #selector(setFade))
            mi.representedObject = value
            fade.addItem(mi)
        }
        menu.addItem(submenu("Fade Over", fade, tag: 105))

        menu.addItem(item("Include External Displays", #selector(toggleExternal), tag: 106))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), tag: 107))
        menu.addItem(.separator())
        menu.addItem(item("Quit ScreenSleep", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.tag = tag
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu, tag: Int) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        mi.tag = tag
        return mi
    }

    /// Refresh checkmarks and the live status line each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }

        menu.item(withTag: 100)?.title = statusLine()
        menu.item(withTag: 101)?.state = prefs.enabled ? .on : .off
        menu.item(withTag: 102)?.title = dimmer.state == .idleWatching ? "Dim Now" : "Restore Brightness"
        menu.item(withTag: 108)?.title = "Undim to \(Int(prefs.undimBrightness * 100))%"
        menu.item(withTag: 106)?.state = prefs.dimExternal ? .on : .off
        menu.item(withTag: 107)?.state = launchAtLoginEnabled ? .on : .off

        if let sub = menu.item(withTag: 103)?.submenu {
            let known = intervalChoices.contains(prefs.idleMinutes)
            for mi in sub.items {
                guard let value = mi.representedObject as? Double else { continue }
                mi.state = (known && value == prefs.idleMinutes) ? .on : .off
            }
            sub.items.last?.state = known ? .off : .on
            sub.items.last?.title = known ? "Custom…" : "Custom: \(formatMinutes(prefs.idleMinutes))…"
        }
        for (tag, current) in [(104, prefs.targetBrightness), (105, prefs.fadeSeconds),
                               (109, prefs.undimBrightness)] {
            for mi in menu.item(withTag: tag)?.submenu?.items ?? [] {
                guard let value = mi.representedObject as? Double else { continue }
                mi.state = value == current ? .on : .off
            }
        }
    }

    private func statusLine() -> String {
        switch dimmer.state {
        case .dimming: return "Dimming…"
        case .dimmed: return "Screen dimmed"
        case .restoring: return "Restoring…"
        case .idleWatching:
            guard prefs.enabled else { return "Auto Dimmer is off" }
            let anyInput = CGEventType(rawValue: ~0)!
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
            let remaining = max(prefs.idleSeconds - idle, 0)
            return "Dims in \(formatSeconds(remaining))"
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        if !prefs.enabled { dimmer.restore() }
        updateIcon(for: dimmer.state)
    }

    @objc private func dimNow() {
        dimmer.toggleDimNow()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        prefs.idleMinutes = minutes
        updateIcon(for: dimmer.state)
    }

    @objc private func setCustomInterval() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%g", prefs.idleMinutes)

        let alert = NSAlert()
        alert.messageText = "Dim after how long?"
        alert.informativeText = "Minutes of inactivity before the screen dims. Decimals are allowed (0.5 = 30 seconds)."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let minutes = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), minutes > 0 {
            prefs.idleMinutes = minutes
            updateIcon(for: dimmer.state)
        }
    }

    @objc private func undimNow() {
        dimmer.undim(to: prefs.undimBrightness)
    }

    @objc private func setUndimTarget(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.undimBrightness = value
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.targetBrightness = value
    }

    @objc private func setFade(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.fadeSeconds = value
    }

    @objc private func toggleExternal() {
        prefs.dimExternal.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nMove ScreenSleep.app to /Applications and try again, or add it manually in System Settings › General › Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Formatting

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 1 { return "\(Int((minutes * 60).rounded())) sec" }
        if minutes == 1 { return "1 minute" }
        if minutes.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(minutes)) minutes" }
        return String(format: "%.1f minutes", minutes)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
