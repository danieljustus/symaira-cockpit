@preconcurrency import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import SymTuneCore

/// `NX_SYSDEFINED`. CoreGraphics has no `CGEventType` case for it — AppKit's
/// `NSEvent.EventType.systemDefined` is the same number seen from the other side.
private let systemDefinedEventType = CGEventType(rawValue: 14)!

/// The `NSSystemDefined` subtype that carries the media / brightness keys.
private let auxControlSubtype: Int16 = 8

/// `NX_KEYTYPE_BRIGHTNESS_UP` / `_DOWN` from IOKit's `ev_keymap.h`.
private let brightnessUpKeyCode: Int32 = 2
private let brightnessDownKeyCode: Int32 = 3

private func brightnessTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<BrightnessKeyController>.fromOpaque(refcon)
        .takeUnretainedValue()
    // The run-loop source is added to the main run loop, so the callback is
    // delivered on the main thread — and it has to answer synchronously:
    // returning nil is what swallows the event, and a hop would hand it back
    // to macOS before the decision was made.
    return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
}

/// Answers the brightness keys in place of macOS, when the user asks for it
/// (issue #250).
///
/// A `CGEventTap` at `.cghidEventTap` sits ahead of the session tap, which is
/// what makes this possible at all: the brightness event can be consumed there
/// before the system draws its own HUD, with no driver and no system extension.
/// Everything that is not a brightness key — volume, media, keyboard
/// illumination — is passed through untouched.
///
/// The brightness write goes through ``TuneController``, the same path the
/// slider uses, so the config's brightness bounds and the history log apply to
/// a key press exactly as they do to a drag.
@MainActor
final class BrightnessKeyController: NSObject {
    /// Why the keys are not currently being answered by this app. Drives what
    /// the preference row explains; `nil` means it is working.
    enum Impediment: Equatable {
        /// The Accessibility grant is missing. Without it an event tap cannot
        /// be created at all.
        case accessibilityNotGranted
        /// No built-in display. External panels need DDC/CI over I2C, which
        /// this does not implement.
        case noBuiltInDisplay
    }

    private let controller: TuneController
    private let hud = BrightnessHUDPanel()

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Cancels the pending Accessibility re-check when the feature is turned
    /// off while it is still waiting for the grant.
    private var grantPollWork: DispatchWorkItem?

    private(set) var isEnabled = false

    /// Published as a plain callback rather than `@Published`: the controller
    /// is an AppKit object shared with the tap's C callback, and the preference
    /// row only needs to know when the explanation changes.
    var onImpedimentChanged: ((Impediment?) -> Void)?

    private(set) var impediment: Impediment? {
        didSet {
            guard impediment != oldValue else { return }
            onImpedimentChanged?(impediment)
        }
    }

    init(controller: TuneController) {
        self.controller = controller
        super.init()
    }

    deinit {
        // The tap outlives its owner otherwise, and a tap with a dangling
        // refcon consuming brightness keys is the worst possible leak here.
        MainActor.assumeIsolated { teardown() }
    }

    // MARK: - Availability

    /// Whether this Mac has a display these keys could act on.
    static var hasBuiltInDisplay: Bool {
        let main = CGMainDisplayID()
        if CGDisplayIsBuiltin(main) != 0 { return true }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Whether the Accessibility grant this needs is in place.
    ///
    /// The grant is keyed to the bundle's code signature, so an unsigned or
    /// re-signed build reads to macOS as a different app and has to be granted
    /// again.
    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Ask for the Accessibility grant, showing the system's own prompt.
    ///
    /// Called from the preference row, never on launch: a permission dialog
    /// nobody asked for is exactly what the default-off setting avoids.
    static func requestAccessibilityGrant() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open the System Settings pane that holds the grant, for the case where
    /// the prompt has already been answered once and will not appear again.
    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Enabling

    /// Turn the interception on or off. Takes effect immediately, in both
    /// directions, so the preference is not a promise about the next launch.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            installTap()
        } else {
            teardown()
            impediment = nil
        }
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard isEnabled, machPort == nil else { return }

        guard Self.hasBuiltInDisplay else {
            impediment = .noBuiltInDisplay
            return
        }
        guard Self.isAccessibilityGranted else {
            impediment = .accessibilityNotGranted
            pollForGrant()
            return
        }

        let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate fails for exactly one reason in practice: the grant is
            // recorded but not yet effective for this process.
            impediment = .accessibilityNotGranted
            pollForGrant()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        runLoopSource = source
        impediment = nil
    }

    /// Retry until the grant lands.
    ///
    /// The Accessibility dialog is answered outside this process and sends no
    /// notification, so the alternative is a feature that stays dead until the
    /// user thinks to relaunch.
    private func pollForGrant() {
        guard grantPollWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.grantPollWork = nil
                guard self.isEnabled, self.machPort == nil else { return }
                self.installTap()
                if self.machPort == nil { self.pollForGrant() }
            }
        }
        grantPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func teardown() {
        grantPollWork?.cancel()
        grantPollWork = nil
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let machPort {
            CFMachPortInvalidate(machPort)
        }
        machPort = nil
        runLoopSource = nil
        hud.dismissImmediately()
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that blocks for too long, and after some kinds
        // of user input. Dying silently here is the classic way a feature like
        // this "just stops working one day", so re-arm instead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled,
              type == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxControlSubtype
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        // Volume, mute, keyboard illumination and the media keys are none of
        // this feature's business.
        guard keyCode == brightnessUpKeyCode || keyCode == brightnessDownKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // With secure input active — a password field has focus — the keyboard
        // belongs to the system. This is a boundary, not a bug: hand the event
        // back and draw nothing.
        guard !IsSecureEventInputEnabled() else {
            return Unmanaged.passUnretained(event)
        }

        let flags = data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0x0A

        if isDown {
            // Shift+Option is the system's fine-adjust chord: quarter steps.
            let fine = nsEvent.modifierFlags.contains(.shift)
                && nsEvent.modifierFlags.contains(.option)
            let direction: BrightnessKeyStep.Direction =
                keyCode == brightnessUpKeyCode ? .up : .down
            apply(direction: direction, fine: fine)
        }

        return nil
    }

    /// Step from the level the display actually holds, never from a running
    /// total: anything else drifts the moment auto-brightness, Control Center
    /// or a wake from sleep moves brightness behind this app's back.
    private func apply(direction: BrightnessKeyStep.Direction, fine: Bool) {
        guard let current = try? controller.getBuiltinBrightness() else { return }
        let target = BrightnessKeyStep.next(
            from: Float(current),
            direction: direction,
            fine: fine
        )
        // The HUD reflects the request even if the write is refused: the config
        // can bound brightness below the key's range, and a HUD that ignores
        // the press entirely reads as a dead key.
        try? controller.applyBuiltinBrightness(Double(target))
        let shown = (try? controller.getBuiltinBrightness()).map(Float.init) ?? target
        hud.show(level: shown)
    }
}
