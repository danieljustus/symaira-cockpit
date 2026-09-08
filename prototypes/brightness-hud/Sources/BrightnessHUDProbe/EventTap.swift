import AppKit
import CoreGraphics

/// `NX_SYSDEFINED`. CoreGraphics has no `CGEventType` case for it — AppKit's
/// `NSEvent.EventType.systemDefined` is the same number, seen from the other side.
private let systemDefinedEventType = CGEventType(rawValue: 14)!

/// The `NSSystemDefined` subtype that carries the media / brightness keys.
private let auxControlSubtype: Int16 = 8

/// `NX_KEYTYPE_*` values from IOKit's `ev_keymap.h`.
private enum AuxKey: Int32 {
    case soundUp = 0, soundDown = 1
    case brightnessUp = 2, brightnessDown = 3
    case mute = 7
    case illuminationUp = 21, illuminationDown = 22, illuminationToggle = 23

    var name: String {
        switch self {
        case .soundUp: "SOUND_UP"
        case .soundDown: "SOUND_DOWN"
        case .brightnessUp: "BRIGHTNESS_UP"
        case .brightnessDown: "BRIGHTNESS_DOWN"
        case .mute: "MUTE"
        case .illuminationUp: "ILLUMINATION_UP"
        case .illuminationDown: "ILLUMINATION_DOWN"
        case .illuminationToggle: "ILLUMINATION_TOGGLE"
        }
    }
}

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<BrightnessEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

final class BrightnessEventTap {
    /// Where in the pipeline to insert. `.cghidEventTap` sits ahead of the
    /// session tap, which is the interesting question: does swallowing there
    /// beat the system to its own HUD?
    let location: CGEventTapLocation
    /// When false the tap only observes — the native HUD still appears. Use it
    /// to confirm the events arrive before testing whether they can be eaten.
    let consume: Bool

    /// When true the probe logs what it would do and leaves brightness alone.
    let dryRun: Bool

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let hud: HUDPanel
    private let display: CGDirectDisplayID?
    /// Only used in dry-run, where there is no real value to step from.
    private var simulatedLevel: Float = 0.5

    @MainActor
    init(location: CGEventTapLocation, consume: Bool, dryRun: Bool, hud: HUDPanel) {
        self.location = location
        self.consume = consume
        self.dryRun = dryRun
        self.hud = hud
        display = Brightness.targetDisplay()

        if let display {
            let level = Brightness.current(display)
            Log.write("brightness: built-in display \(display), level \(level.map { String(format: "%.3f", $0) } ?? "unreadable")")
            simulatedLevel = level ?? 0.5
        } else {
            Log.write("brightness: no built-in display found — external panels need DDC/CI, not implemented here")
        }
        Log.write("brightness: mode=\(dryRun ? "dry-run (never writes)" : "live (writes via DisplayServices)")")
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: consume ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("tap: CGEvent.tapCreate returned nil — Accessibility permission missing?")
            return false
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.write("tap: active at \(location.label), mode=\(consume ? "consume" : "observe")")
        return true
    }

    /// Steps brightness from the value the display actually holds, not from a
    /// running total — anything else drifts as soon as something changes
    /// brightness behind our back (auto-brightness, Control Center, sleep).
    private func apply(delta: Float, fine: Bool) -> Float {
        guard let display, !dryRun else {
            simulatedLevel = min(1, max(0, simulatedLevel + delta))
            if dryRun { Log.write("brightness: dry-run, not writing") }
            return simulatedLevel
        }

        let base = Brightness.current(display) ?? simulatedLevel
        // Snap to the step grid first, so a press off-grid lands on it rather
        // than carrying the offset forever. This is what the system HUD does.
        let grid = fine ? Brightness.fineStep : Brightness.step
        let snapped = (base / grid).rounded() * grid
        let target = min(1, max(0, snapped + delta))

        if !Brightness.set(display, to: target) {
            Log.write("brightness: write failed, HUD shows the requested value anyway")
        }
        simulatedLevel = target
        return target
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that blocks for too long, and after some
        // user input. Silently dying here is the classic way this feature
        // "randomly stops working", so re-arm and say so.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("tap: disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxControlSubtype
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let flags = data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (flags & 0x1) == 1
        let key = AuxKey(rawValue: keyCode)
        let label = key?.name ?? "UNKNOWN(\(keyCode))"

        guard key == .brightnessUp || key == .brightnessDown else {
            // Everything else is logged and passed through untouched — the probe
            // is deliberately blind to volume and media keys.
            Log.write("aux: \(label) \(isDown ? "down" : "up")\(isRepeat ? " repeat" : "") — passed through")
            return Unmanaged.passUnretained(event)
        }

        if isDown {
            // Shift+Option is the system's fine-adjust chord: quarter steps.
            let fine = nsEvent.modifierFlags.contains(.shift)
                && nsEvent.modifierFlags.contains(.option)
            let magnitude = fine ? Brightness.fineStep : Brightness.step
            let delta = key == .brightnessUp ? magnitude : -magnitude

            let level = apply(delta: delta, fine: fine)
            Log.write("""
            \(label) down\(isRepeat ? " (repeat)" : "")\(fine ? " (fine)" : "") — \
            level \(String(format: "%.3f", level)); \
            \(consume ? "consuming event" : "passing event through")
            """)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.hud.show(level: level) }
            }
        } else {
            Log.write("\(label) up — \(consume ? "consuming event" : "passing event through")")
        }

        return consume ? nil : Unmanaged.passUnretained(event)
    }
}

extension CGEventTapLocation {
    var label: String {
        switch self {
        case .cghidEventTap: "cghidEventTap"
        case .cgSessionEventTap: "cgSessionEventTap"
        case .cgAnnotatedSessionEventTap: "cgAnnotatedSessionEventTap"
        @unknown default: "unknown"
        }
    }
}
