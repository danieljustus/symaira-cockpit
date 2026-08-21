@preconcurrency import AppKit
import Combine
import SymTuneCore
import SwiftUI
import SymairaUpdateCheck

/// Manages the menu-bar status item: icon and NSPopover dropdown view.
///
/// Clicking the status icon displays the custom SwiftUI-based popover panel
/// containing controls and system readouts.
///
/// Polling is owned by ``TuneViewModel``, which the status item and the popover
/// share. The controller only reacts to text changes, and only touches the
/// status button when the rendered text actually differs — rewriting the
/// attributed title forces a menu-bar re-layout, so doing it on every tick was
/// pure overhead.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let controller: TuneController
    private let preferencesManager: PreferencesManager
    let aiUsagePreferences = AIUsagePreferences()
    private(set) lazy var aiUsageModel = AIUsageViewModel(
        controller: controller,
        preferences: aiUsagePreferences
    )
    private let model: TuneViewModel
    private let processesModel: ProcessesViewModel
    private var preferencesWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    /// Last title rendered into the status button, to skip redundant updates.
    private var renderedSegments: [StatusItemSegment]?
    /// Whether the button currently shows the icon fallback.
    private var showingIconFallback = false

    /// Cached attributes — building these per refresh allocated for nothing.
    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
        .baselineOffset: 1.0,
        .foregroundColor: NSColor.systemYellow,
    ]
    private static let iconBadgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .baselineOffset: 8.0,
    ]

    /// Auto-update preference store for toggling check-on-launch behaviour.
    let autoPrefs = UserDefaultsAutoUpdatePreferenceStore(keyPrefix: "com.symaira.symtune")

    lazy var updateChecker = AppUpdateChecker(
        checker: UpdateChecker(owner: "danieljustus", repo: "symaira-tune"),
        store: UserDefaultsSkippedVersionStore(key: "com.symaira.tune.updateSkippedTag"),
        currentVersion: { TuneVersion.current },
        autoPrefs: autoPrefs
    )

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Load persisted configuration from config.toml so saved preferences
        // survive a relaunch (issue #357). The CLI uses the same loader
        // (main.swift:457); the app must too.
        let config = ConfigPaths().loadConfig()
        self.controller = TuneController(config: config, aiUsageProviders: TuneController.defaultAIUsageProviders())
        let preferences = PreferencesManager(config: config)
        self.preferencesManager = preferences
        self.model = TuneViewModel(controller: controller, preferences: preferences)
        self.processesModel = ProcessesViewModel(controller: controller)
        super.init()
        configureButton()
        setupPopover()
        observePreferences()
        model.onStatusItemTextChanged = { [weak self] segments in
            self?.renderStatusItem(segments: segments)
        }
        // The AI usage readout rides on the same status-item pipeline.
        aiUsageModel.onStatusItemTextChanged = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderStatusItem(segments: self.model.statusItemSegments, force: true)
            }
        }
        model.start()
        aiUsageModel.start()
        checkForUpdatesOnLaunch()
        registerSleepWakeNotifications()
    }

    deinit {
        MainActor.assumeIsolated {
            model.stop()
            aiUsageModel.stop()
        }
    }

    // MARK: - Update checking

    private func checkForUpdatesOnLaunch() {
        Task {
            await updateChecker.checkOnLaunchIfEnabled()
            renderStatusItem(segments: model.statusItemSegments, force: true)
        }
    }

    // MARK: - Preferences

    /// Re-sync the history buffers when the user changes which metrics are on.
    private func observePreferences() {
        preferencesManager.$enabledMetrics
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.model.syncEnabledMetrics() }
            }
            .store(in: &cancellables)

        // AI usage: provider toggles and the refresh interval apply live;
        // a toggle change triggers an immediate refresh so the popover does
        // not wait for the next scheduled tick.
        aiUsagePreferences.$enabledProviders
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.aiUsageModel.refreshNow() }
            }
            .store(in: &cancellables)
        aiUsagePreferences.$menuBarEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.aiUsageModel.refreshNow()
                    self.renderStatusItem(segments: self.model.statusItemSegments, force: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Status item rendering

    /// Render `segments` into the status button. Skips the work when nothing
    /// changed, which is the common case between refreshes.
    private func renderStatusItem(segments: [StatusItemSegment], force: Bool = false) {
        guard let button = statusItem.button else { return }
        let updateAvailable = { if case .available = updateChecker.status { return true } else { return false } }()

        // The AI usage readout is appended to whatever the metrics pipeline
        // rendered, when enabled and data is available.
        var combined = segments
        if !aiUsageModel.statusItemText.isEmpty {
            if !combined.isEmpty {
                combined.append(.text("  "))
            }
            combined.append(.text(aiUsageModel.statusItemText))
        }

        guard force || combined != renderedSegments else { return }
        renderedSegments = combined

        guard !combined.isEmpty else {
            renderIconFallback(button: button, updateAvailable: updateAvailable)
            return
        }

        if showingIconFallback || button.image != nil {
            button.image = nil
            showingIconFallback = false
        }

        let attributed = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .text(let text):
                attributed.append(NSAttributedString(string: text, attributes: Self.titleAttributes))
            case .symbol(let name):
                attributed.append(Self.symbolAttachment(named: name))
            }
        }

        if updateAvailable {
            attributed.append(NSAttributedString(
                string: " \u{26A0}\u{FE0F}",
                attributes: Self.badgeAttributes
            ))
        }
        button.attributedTitle = attributed
        button.toolTip = MetricStyleFormatting.plainText(segments)
    }

    /// An SF Symbol drawn inline in the status-item title.
    ///
    /// A menu-bar title is a string, so an icon has to arrive as a text
    /// attachment. Falls back to the symbol name in text if the system has no
    /// such symbol — better a stray word than a silently missing metric.
    private static func symbolAttachment(named name: String) -> NSAttributedString {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
            return NSAttributedString(string: name, attributes: titleAttributes)
        }
        image.isTemplate = true

        let attachment = NSTextAttachment()
        attachment.image = image
        // Nudge the glyph down onto the text baseline; an attachment otherwise
        // sits on its own bottom edge and rides high next to the digits.
        attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
        return NSAttributedString(attachment: attachment)
    }

    /// Render the fallback icon (and update badge) when no metrics are visible.
    private func renderIconFallback(button: NSStatusBarButton, updateAvailable: Bool) {
        if !showingIconFallback {
            if let image = NSImage(
                systemSymbolName: "slider.horizontal.3",
                accessibilityDescription: "SymairaTune"
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "ST"
            }
            showingIconFallback = true
        }

        button.attributedTitle = updateAvailable
            ? NSAttributedString(string: "\u{26A0}\u{FE0F}", attributes: Self.iconBadgeAttributes)
            : NSAttributedString(string: "")
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // Use a nice control sliders symbol to match the tuning nature of the app
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "SymairaTune") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "ST"
        }
        showingIconFallback = true
        button.action = #selector(togglePopover)
        button.target = self
    }

    /// Vertical space the popover may occupy on `screen`: the menu-bar-free
    /// area, minus room for the popover's arrow, shadow and a small margin.
    /// Falls back to a conservative value when no screen can be determined.
    static func availableContentHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 600 }
        return max(320, screen.visibleFrame.height - 32)
    }

    private var popoverHosting: NSHostingController<MainStatusView>?

    private func makeStatusView(maxHeight: CGFloat) -> MainStatusView {
        MainStatusView(
            controller: controller,
            model: model,
            aiUsageModel: aiUsageModel,
            processesModel: processesModel,
            updateChecker: updateChecker,
            preferencesManager: preferencesManager,
            openPreferences: { [weak self] in self?.openPreferences() },
            maxHeight: maxHeight
        )
    }

    private func setupPopover() {
        let hosting = NSHostingController(
            rootView: makeStatusView(
                maxHeight: Self.availableContentHeight(for: NSScreen.main)
            )
        )
        popoverHosting = hosting
        // Without preferredContentSize sizing, the SwiftUI content reports its
        // height only after the popover is shown (and again on every periodic
        // refresh), so the popover window gets anchored with a stale frame and
        // ends up clipped above the menu bar instead of hanging below the icon.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        popover.behavior = .transient
        popover.delegate = self
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The menu bar may have moved to a different-sized display since
            // the last open, so re-derive the height budget before showing.
            let screen = button.window?.screen ?? NSScreen.main
            popoverHosting?.rootView = makeStatusView(
                maxHeight: Self.availableContentHeight(for: screen)
            )
            // Show first, then activate: activating an LSUIElement app before
            // the popover is anchored can misplace the popover window.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Switch the model to the interactive tier (faster cadence, full
            // sensor set) now that the panel is on screen.
            model.setDetailVisible(true)
        }
    }

    /// Open the Preferences window.
    func openPreferences() {
        if let window = preferencesWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let prefsView = PreferencesView(
            manager: preferencesManager,
            autoPrefs: autoPrefs,
            aiUsage: aiUsagePreferences,
            aiUsageProviders: aiUsageModel.providers,
            onCredentialChange: { [weak self] in
                // A key was saved/cleared: the provider now resolves lazily,
                // but its cached snapshot must be dropped and the usage card
                // refreshed so the live state shows immediately (issue #324).
                self?.controller.resetAIUsageCache()
                self?.aiUsageModel.refreshNow()
            }
        )
        let hosting = NSHostingController(rootView: prefsView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "SymairaTune Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 420, height: 480))
        window.isReleasedWhenClosed = false
        window.center()

        self.preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Drop back to the idle tier: metrics only, at a glanceable cadence.
        model.setDetailVisible(false)
        // The process card's `onDisappear` is not guaranteed for a popover that
        // is torn down; stop sampling explicitly so a closed panel costs nothing.
        processesModel.setVisible(false)
    }

    // MARK: - Sleep/Wake gap markers

    private func registerSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWake() {
        model.recordWakeGap()
        // The Apple Silicon charge-limit inhibit bit resets on sleep; re-assert
        // the configured limit (band-controlled) after every wake.
        controller.reconcileChargeLimit()
        // macOS also resets the display's gamma table across sleep, which drops
        // an active brightness boost or warmth shift without telling anyone.
        controller.reassertDisplayOverrides()
    }
}
