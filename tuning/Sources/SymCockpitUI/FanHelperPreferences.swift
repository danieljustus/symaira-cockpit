import Combine
import Foundation
import SymCockpitCore
import SymCockpitHelperKit

/// State behind the "Privileged fan helper" preferences section (issue #405).
///
/// Opt-in and off by default. The toggle persists the preference in the
/// grandfathered `com.symaira.symtune` namespace and registers (or removes)
/// the embedded launch daemon. A build that is not Developer-ID signed
/// reports the helper as unavailable and never attempts registration.
@MainActor
final class FanHelperPreferences: ObservableObject {
    @Published private(set) var availability: FanHelperAvailability
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    private let client: FanHelperClient
    private let defaults: UserDefaults

    init(client: FanHelperClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.availability = client.availability()
    }

    /// The persisted opt-in.
    var isOptedIn: Bool { FanHelperDefaults.isEnabled(defaults) }

    /// Whether the toggle can be used on this build at all.
    var canEnable: Bool {
        if case .unavailable = availability { return false }
        return true
    }

    func refresh() { availability = client.availability() }

    /// One honest line about where things stand.
    var statusLine: String {
        switch availability {
        case .unavailable(.unsigned):
            return "Not available in this build. The helper needs a release-signed, notarized Symaira Cockpit; fan control keeps asking for your administrator password."
        case .unavailable(.notBundled):
            return "This build does not include the helper. Fan control keeps asking for your administrator password."
        case .off:
            return "Off. Fan control asks for your administrator password."
        case .notRegistered:
            return "Turned on, but the helper is not registered yet."
        case .requiresApproval:
            return "Waiting for your approval in System Settings → General → Login Items & Extensions. Until then fan control still asks for your administrator password."
        case .enabled:
            return "On. Fan changes need no password. The fans return to the system curve a few seconds after Symaira Cockpit quits."
        }
    }

    var needsApproval: Bool { availability == .requiresApproval }

    func setOptedIn(_ on: Bool) {
        guard !isWorking else { return }
        if on {
            guard canEnable else { return }
            defaults.set(true, forKey: FanHelperDefaults.enabledKey)
            run("Could not register the helper") { try self.client.register() }
        } else {
            // The opt-in is cleared only once the daemon is really gone: a
            // failed unregister must not leave it registered with the UI off.
            run("Could not remove the helper", onSuccess: {
                self.defaults.set(false, forKey: FanHelperDefaults.enabledKey)
            }) {
                try self.client.unregister()
                return self.client.availability()
            }
        }
        objectWillChange.send()
    }

    func openSystemSettings() { client.openSystemSettings() }

    private func run(
        _ failure: String,
        onSuccess: (@MainActor () -> Void)? = nil,
        _ work: @escaping @Sendable () throws -> FanHelperAvailability
    ) {
        isWorking = true
        message = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                availability = result
                onSuccess?()
            } catch {
                let detail = "\(failure): \(error.localizedDescription)"
                message = onSuccess == nil ? detail : detail + " The helper stays registered and the setting stays on."
                availability = client.availability()
            }
            isWorking = false
        }
    }
}
