import Foundation

/// A credential that is read from its source on first use and then remembered.
///
/// Providers used to resolve their credentials in `init`. That made the mere
/// act of *listing* the provider catalog — which every CLI invocation and every
/// app launch does, before any user has enabled anything — read the Keychain.
/// A Keychain item whose ACL does not list the calling binary answers that read
/// with a system dialog, so users who had never turned on a single AI-usage
/// provider still got prompted, once per launch, for an entry the app was not
/// going to use.
///
/// Resolving lazily moves that read to the first fetch of a provider the user
/// actually enabled. ``invalidate()`` drops the memo so a credential the user
/// just saved takes effect without a relaunch.
///
/// `@unchecked Sendable` is carried by the lock: `resolve` is `@Sendable` and
/// every access to `cached` happens under `lock`.
final class CredentialCache<Value>: @unchecked Sendable {
    private let resolve: @Sendable () -> Value
    private let lock = NSLock()
    private var cached: Value?

    init(_ resolve: @escaping @Sendable () -> Value) {
        self.resolve = resolve
    }

    /// The resolved value, reading the underlying source at most once between
    /// ``invalidate()`` calls.
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let resolved = resolve()
        cached = resolved
        return resolved
    }

    /// Forget the memo; the next read hits the source again.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
