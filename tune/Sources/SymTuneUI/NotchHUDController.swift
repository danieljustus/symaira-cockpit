@preconcurrency import AppKit
import SwiftUI
import SymTuneCore

/// The panel the notch HUD draws into (issue #224).
///
/// Borderless and non-activating, so hovering or clicking it never pulls the
/// accessory app in front of whatever the user is working in, and floating at
/// the status-item level so it sits above ordinary windows without covering
/// menus that are actually open.
final class NotchHUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        // Present on every space, on the active space's screen, and not
        // swallowed when another app goes full screen — the menu bar strip is
        // exactly where a full-screen app expects to find overlays.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Never becomes key: a HUD that steals focus from the editor under it
        // is worse than no HUD.
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        // Deliberately left at the default sharing type: excluding the panel
        // from capture would make it vanish from the user's own screenshots,
        // which is a worse surprise than appearing in them.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the notch HUD: its panel, the screen it belongs to, and the hover that
/// expands it.
///
/// The HUD is opt-in and additional — the status item is untouched whether it
/// runs or not — and it exists only while both the preference is on and the
/// host screen actually has a cutout. Everything it displays comes from the
/// shared ``TuneViewModel``, per the "the GUI owns no logic" rule.
@MainActor
final class NotchHUDController: NSObject {
    private let model: TuneViewModel
    private let preferences: PreferencesManager

    private var panel: NotchHUDPanel?
    private var hosting: NSHostingView<NotchHUDView>?
    private var trackingArea: NSTrackingArea?
    private var isExpanded = false
    /// Cancels a pending collapse when the pointer comes back.
    private var collapseWork: DispatchWorkItem?

    /// Opens the Tune popover on the status item.
    var openPanel: () -> Void = {}
    /// Opens the cockpit window; `nil` in the standalone Tune app, which has
    /// none.
    var openCockpit: (() -> Void)?
    var openCockpitTitle: String = "Cockpit"

    /// How long the pointer may be off the HUD before it collapses. Without
    /// the grace period, crossing the cutout — where the pointer leaves the
    /// panel's tracking rect for a frame — collapses it mid-gesture.
    private static let collapseDelay: TimeInterval = 0.25

    init(model: TuneViewModel, preferences: PreferencesManager) {
        self.model = model
        self.preferences = preferences
        super.init()
    }

    deinit {
        MainActor.assumeIsolated { teardown() }
    }

    // MARK: - Availability

    /// The screen that carries the menu bar and has a cutout, if any.
    ///
    /// Only the display with the menu bar can host the HUD: the cutout on any
    /// other screen has no menu bar strip to blend into.
    static func hostScreen() -> NSScreen? {
        guard let main = NSScreen.screens.first else { return nil }
        return NotchLayout.supportsHUD(screenMetrics(main)) ? main : nil
    }

    /// Whether this Mac can show the HUD at all — false on every external
    /// display, Mac mini and pre-2021 MacBook.
    static var isAvailable: Bool { hostScreen() != nil }

    /// Read the numbers `NotchLayout` works from off an `NSScreen`.
    static func screenMetrics(_ screen: NSScreen) -> NotchScreenMetrics {
        NotchScreenMetrics(
            frame: screen.frame,
            menuBarHeight: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    // MARK: - Enabling

    private(set) var isEnabled = false

    /// Turn the HUD on or off. Takes effect immediately, in both directions,
    /// so the preference switch is not a promise about the next launch.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observeScreenChanges()
            rebuild()
        } else {
            stopObservingScreenChanges()
            teardown()
        }
    }

    // MARK: - Panel lifecycle

    /// Build the panel for the current screen, or tear it down if this Mac's
    /// menu bar screen has no cutout right now (clamshell, display swap).
    private func rebuild() {
        guard isEnabled,
              let screen = Self.hostScreen(),
              let collapsed = NotchLayout.collapsedFrame(Self.screenMetrics(screen))
        else {
            teardown()
            return
        }

        let metrics = Self.screenMetrics(screen)
        let view = NotchHUDView(
            model: model,
            preferences: preferences,
            notchWidth: NotchLayout.notchWidth(metrics) ?? 0,
            shoulderWidth: NotchLayout.shoulderWidth(metrics) ?? 0,
            menuBarHeight: metrics.menuBarHeight,
            isExpanded: isExpanded,
            openPanel: { [weak self] in self?.handleOpenPanel() },
            openCockpit: { [weak self] in self?.handleOpenCockpit() },
            openCockpitTitle: openCockpitTitle
        )

        if let hosting {
            hosting.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            let panel = NotchHUDPanel(contentRect: collapsed)
            panel.contentView = host
            self.hosting = host
            self.panel = panel
            installTracking(on: host)
            panel.orderFrontRegardless()
        }

        applyFrame(expanded: isExpanded, screen: screen, animated: false)
    }

    private func teardown() {
        collapseWork?.cancel()
        collapseWork = nil
        if let hosting, let trackingArea {
            hosting.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        isExpanded = false
    }

    /// Move the panel to its collapsed or expanded frame.
    private func applyFrame(expanded: Bool, screen: NSScreen, animated: Bool) {
        guard let panel else { return }
        let metrics = Self.screenMetrics(screen)
        let frame = expanded
            ? NotchLayout.expandedFrame(metrics)
            : NotchLayout.collapsedFrame(metrics)
        guard let frame else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Hover

    /// `.activeAlways` because the HUD has to react while another app is
    /// frontmost — which is the normal case for an accessory app.
    private func installTracking(on view: NSView) {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    /// Not an override: the tracking area's owner receives these informally,
    /// and `NSObject` declares neither.
    @objc func mouseEntered(with event: NSEvent) {
        collapseWork?.cancel()
        collapseWork = nil
        setExpanded(true)
    }

    @objc func mouseExited(with event: NSEvent) {
        // Delayed, so the pointer crossing the cutout does not collapse a HUD
        // the user is on their way into.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setExpanded(false) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let screen = panel?.screen ?? Self.hostScreen() else { return }
        isExpanded = expanded
        // The expanded card shows the full metric set and reads the sensors,
        // so the model goes to its interactive cadence while it is open — the
        // same switch the popover makes.
        model.setDetailVisible(expanded)
        applyFrame(expanded: expanded, screen: screen, animated: true)
        hosting?.rootView = rootView(expanded: expanded, screen: screen)
    }

    private func rootView(expanded: Bool, screen: NSScreen) -> NotchHUDView {
        let metrics = Self.screenMetrics(screen)
        return NotchHUDView(
            model: model,
            preferences: preferences,
            notchWidth: NotchLayout.notchWidth(metrics) ?? 0,
            shoulderWidth: NotchLayout.shoulderWidth(metrics) ?? 0,
            menuBarHeight: metrics.menuBarHeight,
            isExpanded: expanded,
            openPanel: { [weak self] in self?.handleOpenPanel() },
            openCockpit: { [weak self] in self?.handleOpenCockpit() },
            openCockpitTitle: openCockpitTitle
        )
    }

    // MARK: - Actions

    private func handleOpenPanel() {
        collapse()
        openPanel()
    }

    private func handleOpenCockpit() {
        collapse()
        openCockpit?()
    }

    /// Collapse immediately — the pointer is about to be somewhere else.
    private func collapse() {
        collapseWork?.cancel()
        collapseWork = nil
        setExpanded(false)
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func stopObservingScreenChanges() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Displays arrived, left, or were rearranged: the cutout may have moved,
    /// or the menu bar may now be on a screen that has none.
    @objc private func screenParametersChanged() {
        MainActor.assumeIsolated {
            guard isEnabled else { return }
            collapse()
            rebuild()
        }
    }
}
