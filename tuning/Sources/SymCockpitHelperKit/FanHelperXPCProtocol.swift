import Foundation

/// The XPC surface of the fan helper. Deliberately tiny: the caller can only
/// pick one of the three ``FanProfile`` positions by name plus one bounded
/// temperature, so a compromised peer cannot express a raw RPM or an SMC key. Every write the helper makes
/// still goes through the existing `FanGovernor` / `SMCWritePolicy` clamps.
///
/// Charge-limit writes are intentionally not part of this protocol.
///
/// Replies carry plain Foundation types only (`NSXPCConnection` bridges them
/// without custom class allow-lists).
@objc public protocol FanHelperXPCProtocol {
    /// Start the governor on `profile` (`comfort` or `performance`), or move a
    /// running governor to it. `system` hands the fans back. The reply is nil
    /// on success, or a one-line error.
    ///
    /// `coolTargetCelsius` is the optional Cool-position maximum average
    /// temperature (nil = none). The helper does not trust it: a non-finite
    /// number is refused, a finite one is clamped to the 50...85 degC range,
    /// and it only ever adds cooling.
    func startGovernor(
        profile: String,
        coolTargetCelsius: NSNumber?,
        reply: @escaping (String?) -> Void
    )

    /// Liveness ping. Replies whether a governor is currently running.
    func heartbeat(reply: @escaping (Bool) -> Void)

    /// Stop the governor and restore the fans to what was found.
    func stopGovernor(reply: @escaping () -> Void)

    /// `(state, detail)`: state is one of `idle`, `governing`, `failed`.
    /// `detail` is the profile, the failure message or the last stop reason.
    func status(reply: @escaping (String, String?) -> Void)
}
