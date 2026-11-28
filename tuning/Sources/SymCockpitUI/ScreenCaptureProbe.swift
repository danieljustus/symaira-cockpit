import CoreGraphics
import Darwin
import Foundation

/// "Is anything capturing the screen right now?" for the AI-usage Privacy Mode (#451).
///
/// macOS has no public API for this on AppKit (`NSWindow.sharingType = .none` no longer
/// hides windows from ScreenCaptureKit since macOS 15). The window server's watcher flag
/// covers screen shares, recordings and Screen Sharing; it is private, so it is resolved at
/// runtime with `dlsym` and never linked. Without it the public session dictionary still
/// reports macOS Screen Sharing, but not in-app captures.
/// ponytail: polled, not notified; the private attach/detach notifications would make the
/// swap instant and can be added behind the same function if the poll delay matters.
enum ScreenCaptureProbe {
    private typealias IsWatcherPresent = @convention(c) () -> Bool

    private static let isWatcherPresent: IsWatcherPresent? = {
        let everyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        for name in ["SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent"] {
            if let address = dlsym(everyImage, name) { return unsafeBitCast(address, to: IsWatcherPresent.self) }
        }
        return nil
    }()

    static func isScreenCaptured() -> Bool {
        if let isWatcherPresent { return isWatcherPresent() }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsShared"] as? Bool ?? false
    }
}
