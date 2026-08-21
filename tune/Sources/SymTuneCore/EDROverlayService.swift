@preconcurrency import AppKit
import Metal
import QuartzCore

/// Protocol abstracting extended-brightness ("beyond 100%") operations.
public protocol EDROverlayServiceProtocol: Sendable {
    func applyExtendedBrightness(_ multiplier: Double, displayID: CGDirectDisplayID?) throws
    func removeOverlay(for displayID: CGDirectDisplayID)
    func removeAllOverlays()
    /// The multiplier the user asked for, or `nil` when this display is neutral.
    func currentHeadroom(for displayID: CGDirectDisplayID) -> Double?
    /// The headroom the system currently grants the display (`1.0` = SDR only).
    func systemEDRHeadroom(for displayID: CGDirectDisplayID) -> Double?
    /// The boost actually in effect, or `nil` if nothing is applied.
    func engagedBrightness(for displayID: CGDirectDisplayID) -> Double?
    /// How that boost is being produced.
    func brightnessMode(for displayID: CGDirectDisplayID) -> ExtendedBrightnessMode?
    /// Re-apply the active boost after the system dropped it (sleep/wake,
    /// display reconfiguration).
    func reassert()
}

public extension EDROverlayServiceProtocol {
    func engagedBrightness(for displayID: CGDirectDisplayID) -> Double? { nil }
    func brightnessMode(for displayID: CGDirectDisplayID) -> ExtendedBrightnessMode? { nil }
    func reassert() {}
}

/// Extended brightness: pushes the display above its 100% SDR reference.
///
/// ## How this works — and why the previous version could not
///
/// macOS has no API to set brightness above 100%. What it does have is EDR:
/// while *actual* extended-range content is on screen, the display is granted
/// headroom above SDR white, and output values greater than `1.0` render into
/// that headroom instead of clipping. Two pieces are therefore required:
///
/// 1. **A trigger** — a 1×1 `CAMetalLayer` with
///    `wantsExtendedDynamicRangeContent`, an `rgba16Float` drawable and an
///    extended-linear colour space, which is *actually rendered and presented*.
///    That is what makes the system engage EDR and raise
///    `NSScreen.maximumExtendedDynamicRangeColorComponentValue`.
/// 2. **The boost** — the display's gamma table scaled by the requested
///    multiplier (``DisplayGammaController``), which lifts everything already
///    on screen into the granted headroom.
///
/// The previous implementation created a full-screen `CAMetalLayer` at
/// `opacity = 0`, never presented a drawable, and set a made-up `EDRHeadroom`
/// key via KVC. A layer with no presented content asks for nothing, and
/// `EDRHeadroom` is not a property of anything — so the slider above "Normal"
/// changed nothing at all, while the full-screen layer was still enough to flip
/// the panel into HDR mode, which is why the screen looked different even at
/// neutral. Both halves of that bug are fixed here: the trigger is one pixel
/// and only exists while a boost is active, and the boost is real.
///
/// **Thread safety**: window and Metal work is funnelled to the main thread.
public final class EDROverlayService: EDROverlayServiceProtocol, @unchecked Sendable {

    /// Granted headroom above this counts as "EDR is engaged".
    static let engagedHeadroomThreshold = 1.05
    /// How long to keep asking the display to engage EDR. Engagement is not
    /// instant on real hardware — it takes the system a second or two, and
    /// sometimes it never happens (HDR off, or the system declining).
    static let engageTimeout: TimeInterval = 20.0
    /// Poll cadence while waiting for EDR to engage.
    static let engagePollInterval: TimeInterval = 0.25
    /// Tolerance for "the request is fully applied".
    static let headroomEpsilon = 0.005
    /// How far the gamma lift may go **without** EDR headroom.
    ///
    /// Without headroom, output above SDR white clips instead of getting
    /// brighter: the picture as a whole lifts, and the brightest areas flatten.
    /// A small lift is a real, useful brightening; a large one would just crush
    /// the highlights, so the fallback is capped well below
    /// ``SafetyPolicy/extendedBrightnessMax``.
    static let softwareBoostCap = 1.15

    private struct Target {
        /// What the user asked for.
        var requested: Double
        /// What is currently written to the gamma table (`nil` = nothing).
        var applied: Double?
        /// How ``applied`` is being produced.
        var mode: ExtendedBrightnessMode?
        var trigger: any EDRTriggering
    }

    private let lock = NSLock()
    private var targets: [CGDirectDisplayID: Target] = [:]
    private var engageTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    private let gamma: DisplayGammaController
    /// Reads the headroom the system grants a display. Injected for tests.
    private let headroomProvider: @Sendable (CGDirectDisplayID) -> Double?
    /// Builds the on-screen EDR trigger. Injected for tests.
    private let triggerFactory: @Sendable (CGDirectDisplayID) -> (any EDRTriggering)?

    public init() {
        self.gamma = .shared
        self.headroomProvider = { Self.systemHeadroom(for: $0) }
        self.triggerFactory = { EDRTriggerWindow(displayID: $0) }
    }

    /// Test seam: inject headroom reporting, trigger creation and gamma target.
    internal init(
        gamma: DisplayGammaController,
        headroomProvider: @escaping @Sendable (CGDirectDisplayID) -> Double?,
        triggerFactory: @escaping @Sendable (CGDirectDisplayID) -> (any EDRTriggering)?
    ) {
        self.gamma = gamma
        self.headroomProvider = headroomProvider
        self.triggerFactory = triggerFactory
    }

    deinit {
        removeAllOverlays()
    }

    // MARK: - Public API

    /// Apply extended brightness to a display (the built-in one by default).
    ///
    /// Returns as soon as the trigger is on screen. Engaging EDR takes the
    /// system a moment; the boost is written as soon as the display reports the
    /// headroom, and clamped to it — never beyond what the panel granted.
    public func applyExtendedBrightness(
        _ multiplier: Double,
        displayID: CGDirectDisplayID? = nil
    ) throws {
        let targetID = try displayID ?? DisplayHelpers.builtinDisplayID()

        guard multiplier >= SafetyPolicy.extendedBrightnessMin,
              multiplier <= SafetyPolicy.extendedBrightnessMax
        else {
            throw TuneError.usage(
                "Extended brightness must be between \(SafetyPolicy.extendedBrightnessMin) "
                + "and \(SafetyPolicy.extendedBrightnessMax)."
            )
        }

        // The SDR reference needs no trigger and no boost: neutral means the
        // display is left exactly as the system drives it.
        if multiplier <= SafetyPolicy.extendedBrightnessMin {
            removeOverlay(for: targetID)
            return
        }

        lock.lock()
        if var existing = targets[targetID] {
            existing.requested = multiplier
            targets[targetID] = existing
            lock.unlock()
        } else {
            // Building the trigger creates a window, so it happens outside the
            // lock. That makes this a check-then-act: a second caller can arrive
            // in between and install its own trigger. Whoever loses drops its
            // trigger off screen instead of leaking a 1×1 window that would keep
            // requesting EDR for the rest of the session.
            lock.unlock()
            guard let trigger = triggerFactory(targetID) else {
                throw TuneError.failed("Could not create the EDR trigger for display \(targetID).")
            }
            lock.lock()
            if var winner = targets[targetID] {
                winner.requested = multiplier
                targets[targetID] = winner
                lock.unlock()
                trigger.remove()
            } else {
                targets[targetID] = Target(
                    requested: multiplier,
                    applied: nil,
                    mode: nil,
                    trigger: trigger
                )
                lock.unlock()
            }
        }

        try applyBoostIfEngaged(targetID)
    }

    /// Remove the boost and the trigger for one display (restores SDR).
    public func removeOverlay(for displayID: CGDirectDisplayID) {
        lock.lock()
        let task = engageTasks.removeValue(forKey: displayID)
        let target = targets.removeValue(forKey: displayID)
        lock.unlock()

        task?.cancel()
        guard let target else { return }
        gamma.reset(displayID: displayID)
        target.trigger.remove()
    }

    /// Remove every boost and trigger (full restore to SDR).
    public func removeAllOverlays() {
        lock.lock()
        let all = targets
        let tasks = engageTasks
        targets.removeAll()
        engageTasks.removeAll()
        lock.unlock()

        for (_, task) in tasks { task.cancel() }
        for (displayID, target) in all {
            gamma.reset(displayID: displayID)
            target.trigger.remove()
        }
    }

    public func currentHeadroom(for displayID: CGDirectDisplayID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return targets[displayID]?.requested
    }

    public func engagedBrightness(for displayID: CGDirectDisplayID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return targets[displayID]?.applied
    }

    public func brightnessMode(for displayID: CGDirectDisplayID) -> ExtendedBrightnessMode? {
        lock.lock()
        defer { lock.unlock() }
        return targets[displayID]?.mode
    }

    public func systemEDRHeadroom(for displayID: CGDirectDisplayID) -> Double? {
        headroomProvider(displayID)
    }

    public func reassert() {
        lock.lock()
        let ids = Array(targets.keys)
        lock.unlock()
        for id in ids {
            _ = try? applyBoostIfEngaged(id)
        }
    }

    // MARK: - Engagement

    /// Write the boost for the headroom the display currently grants, and keep
    /// watching until the request is met.
    ///
    /// With EDR engaged the full requested range is available. Without it, a
    /// capped software lift is applied instead — a real brightening that clips
    /// highlights, reported as such.
    ///
    /// Either way the watch keeps running while the applied value is short of
    /// the request. That is not just for the moment EDR engages: the granted
    /// headroom then *grows* over a second or two (measured on an XDR panel:
    /// 1.2 → 12.6). Clamping once at apply time left a request for +45% stuck
    /// at the +20% that happened to be available in that instant.
    @discardableResult
    private func applyBoostIfEngaged(_ displayID: CGDirectDisplayID) throws -> Bool {
        lock.lock()
        guard let target = targets[displayID] else {
            lock.unlock()
            return true
        }
        let requested = target.requested
        lock.unlock()

        target.trigger.render()

        let granted = headroomProvider(displayID) ?? 1.0
        let isEngaged = granted > Self.engagedHeadroomThreshold
        // Never ask for more than the panel granted: beyond the headroom the
        // extra output clips to white instead of getting brighter.
        let effective = isEngaged
            ? min(requested, granted)
            : min(requested, Self.softwareBoostCap)
        let mode: ExtendedBrightnessMode = isEngaged ? .extendedRange : .softwareLift

        try gamma.setBoost(Float(effective), displayID: displayID)

        lock.lock()
        if var updated = targets[displayID] {
            updated.applied = effective
            updated.mode = mode
            targets[displayID] = updated
        }
        lock.unlock()

        let satisfied = effective >= requested - Self.headroomEpsilon
        if !satisfied { startHeadroomWatch(displayID) }
        return satisfied
    }

    /// Poll the granted headroom and re-apply while the request is unmet.
    ///
    /// Ends as soon as the requested multiplier is fully applied, or when the
    /// window closes — a display that never grants headroom keeps the capped
    /// software lift rather than being polled forever.
    private func startHeadroomWatch(_ displayID: CGDirectDisplayID) {
        lock.lock()
        guard engageTasks[displayID] == nil else {
            lock.unlock()
            return
        }
        // The lock is only ever taken inside the synchronous helpers below:
        // `NSLock` is unavailable from an async context.
        let task = Task<Void, Never> { [weak self] in
            let deadline = Date().addingTimeInterval(Self.engageTimeout)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(Self.engagePollInterval))
                guard let self, !Task.isCancelled else { return }
                // Target gone: the user went back to neutral.
                guard self.trigger(for: displayID) != nil else {
                    self.forgetEngageTask(displayID)
                    return
                }
                // Re-applies against the *current* headroom; also re-renders the
                // trigger, since content that stops being presented can stop
                // counting as on-screen EDR.
                if (try? self.applyBoostIfEngaged(displayID)) == true {
                    self.forgetEngageTask(displayID)
                    return
                }
            }
            self?.forgetEngageTask(displayID)
        }
        engageTasks[displayID] = task
        lock.unlock()
    }

    private func trigger(for displayID: CGDirectDisplayID) -> (any EDRTriggering)? {
        lock.lock()
        defer { lock.unlock() }
        return targets[displayID]?.trigger
    }

    private func forgetEngageTask(_ displayID: CGDirectDisplayID) {
        lock.lock()
        engageTasks.removeValue(forKey: displayID)
        lock.unlock()
    }

    private static func systemHeadroom(for displayID: CGDirectDisplayID) -> Double? {
        guard let screen = DisplayHelpers.screenForDisplayID(displayID) else { return nil }
        return Double(screen.maximumExtendedDynamicRangeColorComponentValue)
    }
}

// MARK: - Trigger

/// The on-screen EDR content that makes the system grant headroom.
public protocol EDRTriggering: Sendable {
    /// Present a frame. Cheap, and needed both on creation and whenever the
    /// display reconfigures.
    func render()
    /// Take the trigger off screen.
    func remove()
}

/// A 1×1 borderless window whose `CAMetalLayer` renders extended-range white.
///
/// One pixel is enough: the system grants headroom for the display as soon as
/// *any* EDR content is composited on it. A full-screen layer would cost a
/// screen-sized surface per frame for exactly the same effect.
internal final class EDRTriggerWindow: EDRTriggering, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private var window: NSWindow?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?

    /// Value rendered into the trigger. It only has to be extended-range; the
    /// visible brightening comes from the gamma boost, not from this pixel.
    private static let triggerValue = Double(SafetyPolicy.extendedBrightnessMax)

    init?(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        guard onMain({ self.build(device: device) }) else { return nil }
    }

    func render() {
        onMain { self.presentFrame() }
    }

    func remove() {
        onMain {
            self.window?.orderOut(nil)
            self.window = nil
            self.metalLayer = nil
            self.commandQueue = nil
        }
    }

    // MARK: - Private

    /// Dispatching *synchronously* to the main queue from the main thread traps
    /// libdispatch, and the UI applies brightness from the main thread.
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private func build(device: MTLDevice) -> Bool {
        MainActor.assumeIsolated {
            guard let screen = DisplayHelpers.screenForDisplayID(displayID) else { return false }

            let layer = CAMetalLayer()
            Self.configureMetalLayer(layer, device: device)

            // Top-left corner: on a built-in display the rounded corner mask
            // covers it, and on an external one it is a single pixel at the
            // very edge. The trigger has to be *composited* to count, so it
            // cannot be moved off screen or made fully transparent.
            let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Layer-*hosting* view: the layer must be assigned before
            // `wantsLayer`, otherwise AppKit owns the layer tree and swaps in
            // its own backing layer — which is not EDR-capable, so the trigger
            // renders nothing and the display never grants headroom.
            let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            contentView.layer = layer
            contentView.wantsLayer = true
            window.contentView = contentView

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
            ]
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.orderFrontRegardless()

            self.window = window
            self.metalLayer = layer
            presentFrame()
            return true
        }
    }

    /// EDR needs all three together: the flag, a float pixel format, and an
    /// extended-range colour space. Miss one and the content is downgraded to
    /// SDR — which asks the system for no headroom at all.
    internal static func configureMetalLayer(_ layer: CAMetalLayer, device: MTLDevice) {
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.drawableSize = CGSize(width: 1, height: 1)
        layer.contentsScale = 1.0
    }

    private func presentFrame() {
        MainActor.assumeIsolated {
            guard let layer = metalLayer,
                  let queue = commandQueue,
                  let drawable = layer.nextDrawable() else { return }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(
                Self.triggerValue, Self.triggerValue, Self.triggerValue, 1.0
            )

            guard let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
