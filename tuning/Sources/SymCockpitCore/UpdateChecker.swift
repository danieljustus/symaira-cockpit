import Foundation
import SymairaUpdateCheck

/// Compatibility adapter for Tune's historical update-check API.
///
/// Release discovery, semver parsing, HTTP handling and disk caching all live
/// in `SymairaUpdateCheck`. The adapter remains so package-local callers keep
/// their source compatibility while the shipped cockpit uses the same shared
/// primitive everywhere.
public struct UpdateChecker: Sendable {
    /// Legacy source-compatible semantic version value. Release discovery and
    /// comparison now live in appkit; this nested type remains for package
    /// clients that still parse or compare versions directly.
    public struct SemVer: Comparable, CustomStringConvertible, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int
        public let prerelease: String?

        public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        public static func parse(_ tag: String) -> SemVer? {
            let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let parts = trimmed.split(separator: "-", maxSplits: 1)
            guard let versionPart = parts.first else { return nil }
            let numbers = versionPart.split(separator: ".")
            guard numbers.count == 3,
                  let major = Int(numbers[0]),
                  let minor = Int(numbers[1]),
                  let patch = Int(numbers[2]),
                  major >= 0, minor >= 0, patch >= 0
            else { return nil }

            return SemVer(
                major: major,
                minor: minor,
                patch: patch,
                prerelease: parts.count > 1 ? String(parts[1]) : nil
            )
        }

        public var description: String {
            let base = "\(major).\(minor).\(patch)"
            return prerelease.map { "\(base)-\($0)" } ?? base
        }

        public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (_, nil): return true
            case (nil, _): return false
            case (let left?, let right?): return left < right
            }
        }
    }

    public struct UpdateInfo: Sendable {
        public let updateAvailable: Bool
        public let latestVersion: String
        public let downloadURL: String?
        /// Non-nil when the release lookup could not be completed. A failed
        /// check must never look like a successful up-to-date check.
        public let error: String?

        public init(
            updateAvailable: Bool,
            latestVersion: String,
            downloadURL: String?,
            error: String? = nil
        ) {
            self.updateAvailable = updateAvailable
            self.latestVersion = latestVersion
            self.downloadURL = downloadURL
            self.error = error
        }
    }

    public static let repoOwner = "danieljustus"
    public static let repoName = "symaira-cockpit"
    private static let envOptOutKey = "SYMTUNE_CHECK_UPDATES"
    private static let configKey = "check_updates"

    private let currentVersion: String
    private let underlying: SymairaUpdateCheck.UpdateChecker

    public init(
        currentVersion: String = TuneVersion.current,
        repoOwner: String = Self.repoOwner,
        repoName: String = Self.repoName,
        client: UpdateHTTPClient? = nil,
        cacheDirectory: URL? = nil
    ) {
        self.currentVersion = currentVersion
        self.underlying = SymairaUpdateCheck.UpdateChecker(
            owner: repoOwner,
            repo: repoName,
            client: client ?? URLSession.shared,
            cacheTTL: 24 * 60 * 60,
            cacheDirectory: cacheDirectory
        )
    }

    /// Returns false when the existing Tune opt-out setting disables checks.
    public static func isUpdateCheckEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configPaths: ConfigPaths = ConfigPaths()
    ) -> Bool {
        if let value = env[envOptOutKey]?.lowercased() {
            return value == "1" || value == "true"
        }

        guard let content = try? String(contentsOf: configPaths.configFile, encoding: .utf8) else {
            return true
        }
        let table = TOMLParser().parse(content)
        if let value = table["general", configKey]?.boolValue { return value }
        if let value = table["general", configKey]?.intValue { return value == 1 }
        if let value = table["general", configKey]?.stringValue {
            return value.lowercased() == "true" || value == "1"
        }
        return true
    }

    /// Check for a newer release using the shared appkit implementation.
    public func checkForUpdate(force: Bool = false) async -> UpdateInfo {
        guard Self.isUpdateCheckEnabled() else {
            return UpdateInfo(updateAvailable: false, latestVersion: currentVersion, downloadURL: nil)
        }

        do {
            guard let release = try await underlying.check(currentVersion: currentVersion, force: force) else {
                return UpdateInfo(updateAvailable: false, latestVersion: currentVersion, downloadURL: nil)
            }
            return UpdateInfo(
                updateAvailable: true,
                latestVersion: release.tagName,
                downloadURL: release.htmlURL
            )
        } catch {
            return UpdateInfo(
                updateAvailable: false,
                latestVersion: currentVersion,
                downloadURL: nil,
                error: error.localizedDescription
            )
        }
    }

    /// Source-compatible bridge for Tune tests and older package-local users.
    /// The injected transport is routed through appkit; no GitHub request is
    /// made by this compatibility layer itself.
    public static func checkForUpdate(
        currentVersion: String = TuneVersion.current,
        networkService: NetworkServiceProtocol = URLSessionNetworkService()
    ) async -> UpdateInfo? {
        guard isUpdateCheckEnabled() else { return nil }
        let checker = UpdateChecker(
            currentVersion: currentVersion,
            client: NetworkClientAdapter(networkService: networkService)
        )
        return await checker.checkForUpdate(force: true)
    }

    /// Retained for callers that used to clear Tune's process cache. Appkit's
    /// cache is disk-backed and TTL-bound, so there is no process cache here.
    public static func resetCache() async {}
}

private struct NetworkClientAdapter: UpdateHTTPClient {
    let networkService: NetworkServiceProtocol

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await networkService.fetchData(from: request.url ?? URL(string: "https://invalid.local")!)
    }
}
