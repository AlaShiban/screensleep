import Foundation
import CoreGraphics

/// Reads and writes display backlight level.
///
/// macOS has no public API for this, so we bind the two private entry points that
/// every brightness utility uses, at runtime via dlsym. `DisplayServices*` drives the
/// built-in panel (Apple silicon and Intel); `CoreDisplay_Display_*UserBrightness` is
/// the fallback that also covers some external panels.
enum BrightnessAPI {
    private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias DSCan = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
    private typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        for path in [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        ] {
            if let h = dlopen(path, RTLD_LAZY) { return h }
        }
        return nil
    }()

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let dsGet = sym("DisplayServicesGetBrightness", DSGet.self)
    private static let dsSet = sym("DisplayServicesSetBrightness", DSSet.self)
    private static let dsCan = sym("DisplayServicesCanChangeBrightness", DSCan.self)
    private static let cdGet = sym("CoreDisplay_Display_GetUserBrightness", CDGet.self)
    private static let cdSet = sym("CoreDisplay_Display_SetUserBrightness", CDSet.self)

    static var isAvailable: Bool { dsSet != nil || cdSet != nil }

    /// Every display we are able to both read and write, built-in first.
    static func controllableDisplays(includeExternal: Bool) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            .filter { id in
                let builtin = CGDisplayIsBuiltin(id) != 0
                guard builtin || includeExternal else { return false }
                return get(id) != nil
            }
            .sorted { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsBuiltin($1) == 0 }
    }

    /// Current level, 0.0...1.0, or nil if this display does not expose one.
    static func get(_ id: CGDirectDisplayID) -> Double? {
        if let dsGet {
            var value: Float = 0
            if dsGet(id, &value) == 0, value.isFinite, value >= 0 {
                return Double(value)
            }
        }
        if let cdGet {
            let value = cdGet(id)
            if value.isFinite, value >= 0, value <= 1 { return value }
        }
        return nil
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ level: Double) -> Bool {
        let clamped = min(max(level, 0), 1)
        if let dsSet, dsCan?(id) ?? true, dsSet(id, Float(clamped)) == 0 { return true }
        if let cdSet {
            cdSet(id, clamped)
            return true
        }
        return false
    }
}
