@preconcurrency import AppKit

public final class DimOverlay: @unchecked Sendable {
    nonisolated(unsafe) private var windows: [CGDirectDisplayID: NSWindow] = [:]
    nonisolated(unsafe) private var currentOpacity: Float = 1.0

    public init() {}

    deinit {
        removeAllOverlays()
    }

    public func applyDim(_ opacity: Float) {
        if Thread.isMainThread {
            applyDimOnMain(opacity)
        } else {
            DispatchQueue.main.sync { [self] in applyDimOnMain(opacity) }
        }
    }

    public func removeAllOverlays() {
        if Thread.isMainThread {
            removeAllOnMain()
        } else {
            DispatchQueue.main.sync { [self] in removeAllOnMain() }
        }
    }

    public var dimLevel: Float {
        if Thread.isMainThread {
            return currentOpacity
        } else {
            return DispatchQueue.main.sync { [self] in currentOpacity }
        }
    }

    private nonisolated func applyDimOnMain(_ opacity: Float) {
        MainActor.assumeIsolated {
            // No dimming means no overlay. Keeping a fully transparent
            // screen-sized window per display around left the compositor
            // blending an invisible layer forever, and made "no dim" a
            // different state from "never dimmed".
            guard opacity < 1.0 else {
                removeAllOnMain()
                return
            }

            currentOpacity = opacity
            let overlayAlpha = CGFloat(1.0 - opacity)

            for screen in NSScreen.screens {
                guard let displayID = DisplayHelpers.screenDisplayID(screen) else { continue }

                if let existing = windows[displayID] {
                    existing.alphaValue = overlayAlpha
                    continue
                }

                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.backgroundColor = NSColor.black
                window.alphaValue = overlayAlpha
                window.isOpaque = false
                window.hasShadow = false
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                window.isReleasedWhenClosed = false
                windows[displayID] = window
                window.orderFront(nil)
            }
        }
    }

    private nonisolated func removeAllOnMain() {
        MainActor.assumeIsolated {
            for (_, window) in windows { window.orderOut(nil) }
            windows.removeAll()
            currentOpacity = 1.0
        }
    }
}
