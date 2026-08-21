import Foundation

/// Lightweight update checker that compares the current version against the
/// latest GitHub release. Non-blocking and silent when up-to-date or offline.
/// No third-party dependencies — uses URLSession only.
public enum UpdateChecker {

    // MARK: - Public types

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

        /// Parse a tag like `v0.1.0` or `v0.2.0-beta.1`. Returns `nil` on invalid input.
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

            let prerelease = parts.count > 1 ? String(parts[1]) : nil
            return SemVer(major: major, minor: minor, patch: patch, prerelease: prerelease)
        }

        public var description: String {
            let base = "\(major).\(minor).\(patch)"
            if let pre = prerelease { return "\(base)-\(pre)" }
            return base
        }

        // Pre-release sorts before release (0.2.0-beta.1 < 0.2.0).
        // Pre-release tags compare lexicographically when numeric parts match.
        public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (_, nil): return true
            case (nil, _): return false
            case (let l?, let r?): return l < r
            }
        }

        public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
            lhs.major == rhs.major
                && lhs.minor == rhs.minor
                && lhs.patch == rhs.patch
                && lhs.prerelease == rhs.prerelease
        }
    }

    public struct UpdateInfo: Sendable {
        public let updateAvailable: Bool
        public let latestVersion: String
        public let downloadURL: String?
    }

    // MARK: - Configuration

    private static let repoOwner = "danieljustus"
    private static let repoName = "symaira-tune"
    private static let releaseURL = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    private static let timeoutInterval: TimeInterval = 1
    private static let envOptOutKey = "SYMTUNE_CHECK_UPDATES"
    private static let configKey = "check_updates"

    // MARK: - Session cache

    /// Thread-safe cache for the most recent update check result.
    /// Isolating the cache on an actor removes the need for `nonisolated(unsafe)`
    /// statics and satisfies Swift 6 strict-concurrency checking.
    private actor Cache {
        private var result: UpdateInfo?
        private var fetched = false

        func get() -> UpdateInfo? {
            fetched ? result : nil
        }

        func set(_ value: UpdateInfo) {
            result = value
            fetched = true
        }

        func reset() {
            result = nil
            fetched = false
        }
    }

    private static let cache = Cache()

    static func resetCache() async {
        await cache.reset()
    }

    // MARK: - Public API

    /// Returns `false` if opted out via env or config, `true` otherwise.
    public static func isUpdateCheckEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configPaths: ConfigPaths = ConfigPaths()
    ) -> Bool {
        if let value = env[envOptOutKey]?.lowercased() {
            return value == "1" || value == "true"
        }

        let configFile = configPaths.configFile
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else {
            return true
        }

        let table = TOMLParser().parse(content)
        if let val = table["general", configKey]?.boolValue { return val }
        if let val = table["general", configKey]?.intValue { return val == 1 }
        if let val = table["general", configKey]?.stringValue {
            return val.lowercased() == "true" || val == "1"
        }

        return true
    }

    private enum UpdateCheckError: Error {
        case skipped
        case badResponse
        case invalidPayload
        case invalidCurrentVersion(latestTag: String)
    }

    /// Fetch latest release info. Returns `nil` when opted out. Cached per process.
    public static func checkForUpdate(
        currentVersion: String = TuneVersion.current,
        networkService: NetworkServiceProtocol = URLSessionNetworkService()
    ) async -> UpdateInfo? {
        guard isUpdateCheckEnabled() else { return nil }

        if let cached = await cache.get() { return cached }

        let result: UpdateInfo
        do {
            guard let url = URL(string: releaseURL) else {
                throw UpdateCheckError.skipped
            }

            let (data, response) = try await networkService.fetchData(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                throw UpdateCheckError.badResponse
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let latestVersion = SemVer.parse(tagName)
            else {
                throw UpdateCheckError.invalidPayload
            }

            guard let currentSemVer = SemVer.parse("v\(currentVersion)") else {
                throw UpdateCheckError.invalidCurrentVersion(latestTag: tagName)
            }

            let downloadURL = (json["html_url"] as? String)
            let updateAvailable = latestVersion > currentSemVer

            result = UpdateInfo(
                updateAvailable: updateAvailable,
                latestVersion: tagName,
                downloadURL: downloadURL
            )
        } catch let error as UpdateCheckError {
            switch error {
            case .invalidCurrentVersion(let latestTag):
                result = UpdateInfo(updateAvailable: false, latestVersion: latestTag, downloadURL: nil)
            default:
                result = UpdateInfo(updateAvailable: false, latestVersion: currentVersion, downloadURL: nil)
            }
        } catch {
            result = UpdateInfo(updateAvailable: false, latestVersion: currentVersion, downloadURL: nil)
        }

        await cache.set(result)
        return result
    }
}
