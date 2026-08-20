import Foundation

/// User settings, persisted in UserDefaults.
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let enabled = "enabled"
        static let idleMinutes = "idleMinutes"
        static let targetBrightness = "targetBrightness"
        static let undimBrightness = "undimBrightness"
        static let fadeSeconds = "fadeSeconds"
        static let dimExternal = "dimExternal"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.idleMinutes: 15.0,
            Key.targetBrightness: 0.0,
            Key.undimBrightness: 0.5,
            Key.fadeSeconds: 3.0,
            Key.dimExternal: true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Idle time before dimming. Clamped to at least 5 seconds so the app can never
    /// end up in a state where it dims instantly and can't be used.
    var idleMinutes: Double {
        get { max(defaults.double(forKey: Key.idleMinutes), 5.0 / 60.0) }
        set { defaults.set(newValue, forKey: Key.idleMinutes) }
    }

    var idleSeconds: TimeInterval { idleMinutes * 60 }

    /// Level to dim down to, 0.0...1.0. 0 is the darkest the panel goes.
    var targetBrightness: Double {
        get { min(max(defaults.double(forKey: Key.targetBrightness), 0), 1) }
        set { defaults.set(min(max(newValue, 0), 1), forKey: Key.targetBrightness) }
    }

    /// Level "Undim" jumps to, 0.0...1.0. Unlike a restore, this ignores whatever
    /// brightness the user had before the dim.
    var undimBrightness: Double {
        get { min(max(defaults.double(forKey: Key.undimBrightness), 0), 1) }
        set { defaults.set(min(max(newValue, 0), 1), forKey: Key.undimBrightness) }
    }

    var fadeSeconds: Double {
        get { max(defaults.double(forKey: Key.fadeSeconds), 0) }
        set { defaults.set(newValue, forKey: Key.fadeSeconds) }
    }

    var dimExternal: Bool {
        get { defaults.bool(forKey: Key.dimExternal) }
        set { defaults.set(newValue, forKey: Key.dimExternal) }
    }
}
