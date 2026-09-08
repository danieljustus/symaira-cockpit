@preconcurrency import AppKit
import Combine
import SwiftUI
import SymTuneCore

/// The window the docked HUD lives in.
///
/// It is a **stage**, not a frame around the HUD: it covers the whole display
/// and never moves. Everything the user sees move — collapsing, expanding,
/// being dragged from the cutout to a screen edge — is SwiftUI content
/// animating inside it.
///
/// That is the difference between this and the panel it replaces, and it is the
/// whole reason the motion reads as fluid. Animating an `NSWindow` frame hands
/// the geometry to the window server and the content to SwiftUI, on two
/// timelines that do not agree; a drag animated that way stutters and no amount
/// of easing fixes it. With a fixed stage there is one timeline, and springs,
/// interruption and mid-flight retargeting all come for free.
///
/// The cost is that a transparent window now covers the display, so **hit
/// testing becomes the controller's problem**: see
/// ``HUDDockController/updateHitRegion(_:)``.
final class HUDStagePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        // Buttons in a SwiftUI hosting view only respond in a window that can
        // become key. `.nonactivatingPanel` keeps that from activating the app,
        // so the HUD can be clicked without pulling the accessory app forward.
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        // Starts inert. Nothing is under the pointer yet, and a full-screen
        // panel that swallows clicks before it has drawn anything would eat the
        // user's next click on the desktop.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    /// Key, so its controls work; never main, so it does not take over the
    /// app's window state.
    override var canBecomeMain: Bool { false }
}

/// A click into a window of an app that is not frontmost is normally swallowed:
/// AppKit spends it on bringing the window forward and never delivers it to the
/// control under the pointer. The HUD belongs to an accessory app that is
/// almost never frontmost, so without this every button in it would need two
/// clicks — which reads exactly like a button that does not work.
private final class HUDStageHostingView: NSHostingView<HUDDockView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the docked HUD: the stage it draws on, the dock it is parked in, the
/// hover that expands it, and the drag that moves it between docks.
///
/// Everything it displays comes from the shared ``TuneViewModel``, per the "the
/// GUI owns no logic" rule; everything about *where* it is comes from
/// ``HUDDockLayout``, which is pure and tested.
@MainActor
final class HUDDockController: NSObject {
    private let model: TuneViewModel
    private let preferences: PreferencesManager
    let dockPreferences: HUDDockPreferences

    private var panel: HUDStagePanel?
    private var hosting: HUDStageHostingView?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private var isExpanded = false
    /// True from the first drag change until the drop lands. While it is set,
    /// the stage keeps accepting mouse events wherever the pointer goes —
    /// otherwise the drag would die the moment it left the pill.
    private var isDragging = false
    /// The rectangle, in global screen coordinates, that the stage is currently
    /// willing to accept mouse events in.
    private var hitRegion: CGRect = .zero
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

    init(
        model: TuneViewModel,
        preferences: PreferencesManager,
        dockPreferences: HUDDockPreferences = HUDDockPreferences()
    ) {
        self.model = model
        self.preferences = preferences
        self.dockPreferences = dockPreferences
        super.init()
    }

    deinit {
        MainActor.assumeIsolated { teardown() }
    }

    // MARK: - Availability

    /// The display the HUD lives on: the one carrying the menu bar.
    static func hostScreen() -> NSScreen? { NSScreen.screens.first }

    /// Read the numbers ``HUDDockLayout`` works from off an `NSScreen`.
    static func screenMetrics(_ screen: NSScreen) -> NotchScreenMetrics {
        NotchScreenMetrics(
            frame: screen.frame,
            menuBarHeight: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    /// Whether the HUD can be offered as a readout surface right now.
    ///
    /// Deliberately *not* "any dock renders here", which would be true on every
    /// Mac. A user who chose the HUD back when it only meant the notch chose a
    /// notch; silently relocating them to a screen edge on a Mac mini would be
    /// a surprise the upgrade never asked about. So the edges only count once
    /// the user has actually parked the HUD on one.
    static func isAvailable(dock: HUDDock) -> Bool {
        guard let screen = hostScreen() else { return false }
        return HUDDockLayout.supports(dock, on: screenMetrics(screen))
    }

    // MARK: - Enabling

    private(set) var isEnabled = false

    /// Turn the HUD on or off. Takes effect immediately, in both directions,
    /// so the preference switch is not a promise about the next launch.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observeDockChanges()
            observeScreenChanges()
            rebuild()
        } else {
            cancellables.removeAll()
            stopObservingScreenChanges()
            teardown()
        }
    }

    // MARK: - Stage lifecycle

    /// Build the stage for the current display, or tear it down when no display
    /// can host the chosen dock.
    private func rebuild() {
        guard isEnabled,
              let screen = Self.hostScreen(),
              let dock = HUDDockLayout.effective(dockPreferences.dock, on: Self.screenMetrics(screen))
        else {
            teardown()
            return
        }

        if let panel {
            // The stage tracks the display, not the HUD: a resolution change
            // resizes it, and the content re-lays itself out inside.
            panel.setFrame(screen.frame, display: true)
        } else {
            let panel = HUDStagePanel(contentRect: screen.frame)
            let host = HUDStageHostingView(rootView: rootView(dock: dock, screen: screen))
            panel.contentView = host
            self.hosting = host
            self.panel = panel
            startPointerMonitoring()
            panel.orderFrontRegardless()
        }

        hosting?.rootView = rootView(dock: dock, screen: screen)
        refreshHitRegion(dock: dock, screen: screen)
    }

    private func teardown() {
        collapseWork?.cancel()
        collapseWork = nil
        stopPointerMonitoring()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        isExpanded = false
        isDragging = false
        hitRegion = .zero
    }

    // MARK: - View

    private func rootView(dock: HUDDock, screen: NSScreen) -> HUDDockView {
        let metrics = Self.screenMetrics(screen)
        return HUDDockView(
            model: model,
            preferences: preferences,
            metrics: metrics,
            dock: dock,
            isExpanded: isExpanded,
            notchWidth: NotchLayout.notchWidth(metrics) ?? 0,
            shoulderWidth: NotchLayout.shoulderWidth(metrics) ?? 0,
            menuBarHeight: metrics.menuBarHeight,
            openPanel: { [weak self] in self?.handleOpenPanel() },
            openCockpit: { [weak self] in self?.handleOpenCockpit() },
            openCockpitTitle: openCockpitTitle,
            onDragChanged: { [weak self] point in self?.dragChanged(to: point) },
            onDragEnded: { [weak self] point in self?.dragEnded(at: point) }
        )
    }

    /// Push a fresh view in without rebuilding the stage.
    ///
    /// Replacing `rootView` rather than tearing anything down is what lets
    /// SwiftUI animate from the old geometry to the new one — a rebuilt hosting
    /// view would have no previous state to animate from, and every dock change
    /// would be a jump cut.
    private func refreshView() {
        guard let screen = Self.hostScreen(),
              let dock = HUDDockLayout.effective(dockPreferences.dock, on: Self.screenMetrics(screen))
        else { return }
        hosting?.rootView = rootView(dock: dock, screen: screen)
        refreshHitRegion(dock: dock, screen: screen)
    }

    // MARK: - Hit testing

    /// Which pixels of the stage may take a click.
    ///
    /// A full-screen panel that accepted mouse events everywhere would swallow
    /// every click on the desktop, so the stage is inert by default and only
    /// becomes live while the pointer is inside the HUD itself. During a drag
    /// the region opens to the whole display, because the pointer is by then
    /// somewhere between two docks and the gesture must survive the trip.
    private func refreshHitRegion(dock: HUDDock, screen: NSScreen) {
        let metrics = Self.screenMetrics(screen)
        // Collapsed, the reactive strip is wider than the drawn sliver — see
        // `HUDDockLayout.edgeHoverWidth`. Expanded, the card is its own target.
        let frame = isExpanded
            ? HUDDockLayout.expandedFrame(dock, on: metrics)
            : HUDDockLayout.hoverFrame(dock, on: metrics)
        hitRegion = frame ?? .zero
        updateHitRegion(NSEvent.mouseLocation)
    }

    private func updateHitRegion(_ pointer: CGPoint) {
        guard let panel else { return }
        let live = isDragging || hitRegion.contains(pointer)
        if panel.ignoresMouseEvents == live {
            panel.ignoresMouseEvents = !live
        }
    }

    // MARK: - Hover

    /// Hover is driven by event monitors rather than an `NSTrackingArea`.
    ///
    /// A tracking area only sees mouse-moved events that AppKit delivers to the
    /// window, and for a background accessory app over another app's window
    /// those never arrive — which is precisely the situation the HUD lives in.
    /// A global monitor sees the pointer wherever it is; the local one covers
    /// the case where this app *is* frontmost, because a global monitor does
    /// not fire for its own process.
    ///
    /// Mouse-moved monitoring needs no Accessibility grant. Both handlers do
    /// nothing but a rectangle containment test.
    private func startPointerMonitoring() {
        guard globalPointerMonitor == nil else { return }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    private func stopPointerMonitoring() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
    }

    /// Expand while the pointer is over the HUD, collapse once it leaves.
    private func pointerMoved() {
        guard panel != nil else { return }
        let pointer = NSEvent.mouseLocation
        updateHitRegion(pointer)
        guard !isDragging else { return }

        if hitRegion.contains(pointer) {
            collapseWork?.cancel()
            collapseWork = nil
            setExpanded(true)
        } else if isExpanded {
            scheduleCollapse()
        }
    }

    /// Delayed, so the pointer crossing the cutout — where it is briefly
    /// outside the collapsed strip — does not collapse a HUD the user is on
    /// their way into.
    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        // The expanded card shows the full metric set and reads the sensors,
        // so the model goes to its interactive cadence while it is open — the
        // same switch the popover makes.
        model.setDetailVisible(expanded)
        refreshView()
    }

    // MARK: - Dragging

    /// The HUD is being dragged; `point` is in global screen coordinates.
    private func dragChanged(to point: CGPoint) {
        if !isDragging {
            isDragging = true
            collapseWork?.cancel()
            collapseWork = nil
            // Collapsed while travelling: an expanded card following the
            // pointer across the screen obscures what is underneath it, and
            // the user is choosing a place, not reading numbers.
            setExpanded(false)
        }
        updateHitRegion(point)
    }

    /// The drag ended at `point`, in global screen coordinates.
    ///
    /// A drop that lands near no dock is not an error and does not move the
    /// HUD: it springs back to where it came from, which is the behaviour that
    /// makes an accidental drag harmless.
    private func dragEnded(at point: CGPoint) {
        isDragging = false
        if let screen = Self.hostScreen(),
           let target = HUDDockLayout.nearestDock(to: point, on: Self.screenMetrics(screen)),
           target != dockPreferences.dock {
            // Writing the preference re-enters through `observeDockChanges`,
            // which refreshes the view — one path for a dock change, whether it
            // came from a drag or from the preferences window.
            dockPreferences.dock = target
        } else {
            refreshView()
        }
        updateHitRegion(NSEvent.mouseLocation)
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

    // MARK: - Observation

    private func observeDockChanges() {
        dockPreferences.$dock
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshView() }
            }
            .store(in: &cancellables)
    }

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

    /// Displays arrived, left, or were rearranged: the stage may need resizing,
    /// and the chosen dock may no longer be renderable.
    @objc private func screenParametersChanged() {
        MainActor.assumeIsolated {
            guard isEnabled else { return }
            collapse()
            rebuild()
        }
    }
}
