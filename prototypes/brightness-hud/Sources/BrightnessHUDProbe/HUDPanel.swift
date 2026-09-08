import AppKit

/// A stand-in for the system brightness HUD.
///
/// The shape that matters: a non-activating borderless panel above full-screen
/// apps, click-through, on every Space, with a `.hudWindow` vibrancy backdrop
/// and a 16-segment bar — the same quantisation the system HUD uses.
@MainActor
final class HUDPanel {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private var segments: [NSView] = []
    private var dismissWork: DispatchWorkItem?

    private static let segmentCount = 16
    private static let side: CGFloat = 200
    private static let cornerRadius: CGFloat = 26
    private static let bottomInset: CGFloat = 140

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]

        // Liquid Glass where the OS has it. NSGlassEffectView wraps its content
        // instead of sitting behind it, so the controls go into `contentView`
        // rather than being added as subviews of the backdrop.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        content.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = content
            panel.contentView = glass
        } else {
            // macOS 15 still has to render something; vibrancy is the closest.
            let backdrop = NSVisualEffectView(frame: content.frame)
            backdrop.material = .hudWindow
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.autoresizingMask = [.width, .height]
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = Self.cornerRadius
            backdrop.layer?.cornerCurve = .continuous
            backdrop.layer?.masksToBounds = true
            backdrop.addSubview(content)
            panel.contentView = backdrop
        }
        let backdrop = content

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        iconView.image = NSImage(
            systemSymbolName: "sun.max.fill",
            accessibilityDescription: "Brightness"
        )
        backdrop.addSubview(iconView)

        let bar = NSStackView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.spacing = 2
        bar.distribution = .fillEqually
        for _ in 0 ..< Self.segmentCount {
            let segment = NSView()
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 1
            segment.heightAnchor.constraint(equalToConstant: 8).isActive = true
            segments.append(segment)
            bar.addArrangedSubview(segment)
        }
        backdrop.addSubview(bar)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84),
            bar.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -22),
            bar.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -26),
        ])
    }

    /// Shows the HUD at `level` (0...1) and schedules the fade-out.
    func show(level: Float) {
        let filled = Int((level * Float(Self.segmentCount)).rounded())
        for (index, segment) in segments.enumerated() {
            let on = index < filled
            segment.layer?.backgroundColor = on
                ? NSColor.labelColor.cgColor
                : NSColor.quaternaryLabelColor.cgColor
        }

        reposition()
        dismissWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func reposition() {
        // The screen under the pointer, matching where the system puts its HUD.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.side / 2,
            y: frame.minY + Self.bottomInset
        ))
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }
}
