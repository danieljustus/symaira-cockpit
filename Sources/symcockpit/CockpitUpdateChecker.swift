import Foundation
import SymTuneCore
import SymairaUpdateCheck

/// The one update target for the shipped `symcockpit` binary.
///
/// Keep the repository coordinates here. Family packages retain compatibility
/// adapters for their historical APIs, but the dispatcher and GUI use this
/// cockpit-level configuration so a repository consolidation cannot orphan
/// released users again.
enum CockpitUpdateTarget {
    static let owner = "danieljustus"
    static let repository = "symaira-cockpit"
}

struct CockpitUpdateReport: Encodable {
    let status: String
    let updateAvailable: Bool
    let latestVersion: String?
    let releaseURL: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status
        case updateAvailable = "update_available"
        case latestVersion = "latest_version"
        case releaseURL = "release_url"
        case error
    }

    static func available(_ release: ReleaseInfo) -> Self {
        Self(
            status: "available",
            updateAvailable: true,
            latestVersion: release.tagName,
            releaseURL: release.htmlURL,
            error: nil
        )
    }

    static var upToDate: Self {
        Self(status: "up_to_date", updateAvailable: false, latestVersion: nil, releaseURL: nil, error: nil)
    }

    static var skipped: Self {
        Self(status: "skipped", updateAvailable: false, latestVersion: nil, releaseURL: nil, error: nil)
    }

    static func unavailable(_ error: Error) -> Self {
        Self(
            status: "unavailable",
            updateAvailable: false,
            latestVersion: nil,
            releaseURL: nil,
            error: error.localizedDescription
        )
    }
}

enum CockpitUpdatePolicy {
    static let environmentKey = "SYMCOCKPIT_CHECK_UPDATES"

    static func isEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let value = env[environmentKey]?.lowercased(), !value.isEmpty {
            if ["0", "false", "no", "off"].contains(value) { return false }
        }
        return UpdateChecker.isUpdateCheckEnabled(
            env: env,
            configPaths: ConfigPaths(env: env)
        )
    }
}

/// Performs the update check only when the caller has not opted out.
func checkForCockpitUpdateIfEnabled(
    args: [String] = [],
    env: [String: String] = ProcessInfo.processInfo.environment
) async -> CockpitUpdateReport {
    guard !args.contains("--no-update-check"), CockpitUpdatePolicy.isEnabled(env: env) else {
        return .skipped
    }
    return await checkForCockpitUpdate()
}

/// Performs the single cockpit release check used by dispatcher version output.
func checkForCockpitUpdate(
    currentVersion: String = CockpitVersion.current,
    client: UpdateHTTPClient = URLSession.shared
) async -> CockpitUpdateReport {
    let checker = SymairaUpdateCheck.UpdateChecker(
        owner: CockpitUpdateTarget.owner,
        repo: CockpitUpdateTarget.repository,
        client: client,
        cacheTTL: 24 * 60 * 60
    )
    do {
        guard let release = try await checker.check(currentVersion: currentVersion) else {
            return .upToDate
        }
        return .available(release)
    } catch {
        return .unavailable(error)
    }
}
