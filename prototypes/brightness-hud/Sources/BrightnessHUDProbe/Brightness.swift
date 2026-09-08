import CoreGraphics
import Foundation

/// Reads and writes the internal display's brightness.
///
/// `DisplayServices` is a private framework. It is dlopen'd rather than linked
/// so a missing or renamed symbol degrades to "unavailable" instead of failing
/// to launch — which is exactly the failure mode a shipping version has to
/// survive across a macOS major.
enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias ChangedFn = @convention(c) (UInt32, Double) -> Int32

    /// The step the system uses for a plain key press. Shift+Option quarters it.
    static let step: Float = 1.0 / 16.0
    static let fineStep: Float = 1.0 / 64.0

    private static let handle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            Log.write("brightness: dlopen(DisplayServices) failed — \(String(cString: dlerror()))")
            return nil
        }
        return handle
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else {
            Log.write("brightness: symbol \(name) not found")
            return nil
        }
        return unsafeBitCast(sym, to: type)
    }

    private static let getFn = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    private static let setFn = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    /// Without this, Control Center and the Displays pane keep showing the old
    /// value — they are told about changes, they do not poll.
    private static let changedFn = symbol("DisplayServicesBrightnessChanged", as: ChangedFn.self)

    /// The display the keys should act on: the built-in panel. External displays
    /// need DDC/CI over I2C, which this spike does not implement.
    static func targetDisplay() -> CGDirectDisplayID? {
        let main = CGMainDisplayID()
        if CGDisplayIsBuiltin(main) != 0 { return main }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func current(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        let status = getFn(display, &value)
        guard status == 0 else {
            Log.write("brightness: get returned \(status)")
            return nil
        }
        return value
    }

    /// Sets brightness, clamped to 0...1. Returns false if the private API is
    /// unavailable or refused the write.
    @discardableResult
    static func set(_ display: CGDirectDisplayID, to value: Float) -> Bool {
        guard let setFn else { return false }
        let clamped = min(1, max(0, value))
        let status = setFn(display, clamped)
        guard status == 0 else {
            Log.write("brightness: set returned \(status)")
            return false
        }
        _ = changedFn?(display, Double(clamped))
        return true
    }
}
