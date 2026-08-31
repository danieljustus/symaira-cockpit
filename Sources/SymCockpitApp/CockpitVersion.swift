import Foundation

/// The GUI's own version marker.
///
/// Kept in lockstep with `CockpitVersion.current` in `Sources/symcockpit/
/// main.swift` — the release guard compares the tag against that value, and a
/// GUI that reported a different number would just confuse a bug report. It is
/// duplicated rather than shared because the dispatcher is an executable
/// target, which SwiftPM cannot depend on.
enum CockpitAppVersion {
    static let current = "0.5.1"
}
