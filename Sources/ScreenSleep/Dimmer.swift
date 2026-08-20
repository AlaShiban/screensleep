import AppKit
import CoreGraphics
import os

/// Diagnostics: `log stream --predicate 'subsystem == "com.local.screensleep"'`
let dimLog = Logger(subsystem: "com.local.screensleep", category: "dimmer")

/// Drives the dim/restore cycle: watches the HID idle clock, snapshots the current
/// backlight level, fades it down to the target, and puts it back on the first input.
final class Dimmer {
    enum State: Equatable {
        case idleWatching   // waiting for the idle threshold
        case dimming        // fading down
        case dimmed         // parked at the target level
        case restoring      // fading back up
    }

    private(set) var state: State = .idleWatching {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Called on the main thread whenever the state changes, for the menu bar UI.
    var onStateChange: ((State) -> Void)?

    private let prefs = Preferences.shared
    private var pollTimer: Timer?
    private var fadeTimer: Timer?

    /// Brightness per display as it was the last time the user was demonstrably present.
    /// Sampled continuously while active so that macOS's own pre-sleep dim, or our own
    /// fade, can never be mistaken for the user's chosen level.
    private var lastActiveLevels: [CGDirectDisplayID: Double] = [:]
    private var restoreLevels: [CGDirectDisplayID: Double] = [:]
    /// What we last wrote, so we can tell our own changes from the user's.
    private var lastWritten: [CGDirectDisplayID: Double] = [:]

    private let pollInterval: TimeInterval = 1.0
    private let fadeStepInterval: TimeInterval = 1.0 / 30.0
    /// Idle seconds below which we consider the user actively present, for the purpose
    /// of sampling their chosen brightness.
    private let presenceThreshold: TimeInterval = 5.0
    /// Uptime at which the current dim began. Input older than this is the input that
    /// preceded the dim (e.g. the click on "Dim Now") and must not cancel it.
    private var dimStartedAt: TimeInterval = 0
    /// Slack for poll/fade jitter when comparing the idle clock against the dim start.
    private let wakeMargin: TimeInterval = 1.0

    // MARK: - Lifecycle

    func start() {
        sampleActiveLevels()
        let timer = Timer(timeInterval: pollInterval, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancelFade()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Idle polling

    /// Seconds since the last keyboard, mouse, or trackpad event. Needs no permissions.
    private var idleSeconds: TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private var ticks = 0

    @objc private func tick() {
        ticks += 1
        if ticks % 10 == 0 {
            dimLog.info("tick idle=\(self.idleSeconds, format: .fixed(precision: 1))s threshold=\(self.prefs.idleSeconds)s state=\(String(describing: self.state), privacy: .public) enabled=\(self.prefs.enabled) displays=\(self.displays().count)")
        }

        guard prefs.enabled else {
            if state != .idleWatching { restore() }
            return
        }

        let idle = idleSeconds

        switch state {
        case .idleWatching:
            if idle < presenceThreshold { sampleActiveLevels() }
            if idle >= prefs.idleSeconds { dim() }
        case .dimming, .dimmed:
            // Wake only on input that arrived *after* we started dimming — otherwise the
            // very click that asked for the dim would cancel it on the next tick.
            let sinceDim = ProcessInfo.processInfo.systemUptime - dimStartedAt
            if idle + wakeMargin < sinceDim { restore() }
        case .restoring:
            break
        }
    }

    /// Record the user's current brightness, ignoring displays we are mid-fade on.
    private func sampleActiveLevels() {
        for id in displays() {
            guard let level = BrightnessAPI.get(id) else { continue }
            lastActiveLevels[id] = level
        }
    }

    private func displays() -> [CGDirectDisplayID] {
        BrightnessAPI.controllableDisplays(includeExternal: prefs.dimExternal)
    }

    // MARK: - Dim / restore

    /// Fade every controllable display down to the target level.
    func dim() {
        guard state == .idleWatching else {
            dimLog.info("dim() ignored, state=\(String(describing: self.state), privacy: .public)")
            return
        }
        let ids = displays()
        dimLog.info("dim() starting, \(ids.count) display(s), target=\(self.prefs.targetBrightness)")
        guard !ids.isEmpty else {
            dimLog.error("dim() aborted: no controllable displays")
            return
        }

        restoreLevels = [:]
        var from: [CGDirectDisplayID: Double] = [:]
        for id in ids {
            guard let current = BrightnessAPI.get(id) else { continue }
            // Prefer the level from when the user was last present: if macOS already
            // started its own pre-sleep fade, `current` would be misleadingly low.
            let saved = max(lastActiveLevels[id] ?? current, current)
            restoreLevels[id] = saved
            from[id] = current
        }
        guard !restoreLevels.isEmpty else { return }

        state = .dimming
        dimStartedAt = ProcessInfo.processInfo.systemUptime
        let target = prefs.targetBrightness
        fade(from: from, to: ids.reduce(into: [:]) { $0[$1] = target }) { [weak self] in
            guard let self else { return }
            self.state = .dimmed
            dimLog.info("dimmed, panel now at \(BrightnessAPI.get(CGMainDisplayID()) ?? -1, format: .fixed(precision: 3))")
        }
    }

    /// Put the brightness back where the user had it.
    func restore() {
        guard state == .dimming || state == .dimmed || state == .restoring else { return }
        dimLog.info("restore() from state=\(String(describing: self.state), privacy: .public) idle=\(self.idleSeconds, format: .fixed(precision: 1))s")
        cancelFade()

        var from: [CGDirectDisplayID: Double] = [:]
        var to: [CGDirectDisplayID: Double] = [:]
        for (id, saved) in restoreLevels {
            guard let current = BrightnessAPI.get(id) else { continue }
            // If the level no longer matches what we wrote, the user (or the system)
            // took the wheel while we were dimmed — leave their choice alone.
            if let written = lastWritten[id], abs(written - current) > 0.03 { continue }
            from[id] = current
            to[id] = saved
        }

        guard !to.isEmpty else {
            finishRestore()
            return
        }

        state = .restoring
        fade(from: from, to: to) { [weak self] in
            self?.finishRestore()
        }
    }

    /// Bring the screen back to a fixed level rather than the remembered one. Works from
    /// any state — dimmed, mid-fade, or already awake — so it doubles as a "give me a
    /// usable screen right now" escape hatch if a restore ever lands somewhere wrong.
    func undim(to level: Double) {
        cancelFade()
        let ids = displays()
        dimLog.info("undim() to \(level, format: .fixed(precision: 2)) from state=\(String(describing: self.state), privacy: .public)")
        guard !ids.isEmpty else { return }

        var from: [CGDirectDisplayID: Double] = [:]
        for id in ids { from[id] = BrightnessAPI.get(id) ?? level }

        state = .restoring
        fade(from: from, to: ids.reduce(into: [:]) { $0[$1] = level }) { [weak self] in
            self?.finishRestore()
        }
    }

    private func finishRestore() {
        restoreLevels = [:]
        lastWritten = [:]
        state = .idleWatching
        sampleActiveLevels()
    }

    /// Toggle used by the menu's "Dim Now" / "Restore" item.
    func toggleDimNow() {
        switch state {
        case .idleWatching: dim()
        case .dimming, .dimmed, .restoring: restore()
        }
    }

    // MARK: - Fading

    private func fade(from: [CGDirectDisplayID: Double],
                      to: [CGDirectDisplayID: Double],
                      completion: @escaping () -> Void) {
        cancelFade()

        let duration = prefs.fadeSeconds
        guard duration > 0.01 else {
            for (id, level) in to { write(id, level) }
            completion()
            return
        }

        let steps = max(Int(duration / fadeStepInterval), 1)
        var step = 0
        let timer = Timer(timeInterval: fadeStepInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            step += 1
            let p = min(Double(step) / Double(steps), 1.0)
            // Ease-out: most of the change happens early, so the last stretch into
            // black feels gradual rather than like a cut.
            let eased = 1 - pow(1 - p, 2)
            for (id, target) in to {
                let start = from[id] ?? BrightnessAPI.get(id) ?? target
                self.write(id, start + (target - start) * eased)
            }
            if p >= 1.0 {
                t.invalidate()
                self.fadeTimer = nil
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func write(_ id: CGDirectDisplayID, _ level: Double) {
        BrightnessAPI.set(id, level)
        lastWritten[id] = level
    }

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: - Sleep / wake

    @objc private func systemWillSleep() {
        cancelFade()
    }

    @objc private func systemDidWake() {
        // The panel comes back under the system's control; hand the user their level back.
        guard state != .idleWatching else {
            sampleActiveLevels()
            return
        }
        for (id, saved) in restoreLevels { BrightnessAPI.set(id, saved) }
        finishRestore()
    }
}
