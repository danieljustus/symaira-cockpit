import XCTest
import SymCockpitCore
@testable import SymCockpitUI

/// #450: the priority strip in the menu bar and the quota alerts, end to end through the view model.
final class AIUsagePriorityStripTests: XCTestCase {
    @MainActor
    private func setUp(_ meters: [AIUsageMeter]) -> (AIUsageViewModel, AIUsagePreferences) {
        let name = NSTemporaryDirectory() + "AIUsagePriorityStripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.enabledProviders = ["p"]
        preferences.menuBarEnabled = true
        let model = AIUsageViewModel(providers: [], preferences: preferences, fetch: { _, _ in [] })
        model.requestNotificationPermission = {}
        model.apply([.init(providerID: "p", snapshot: snapshot(meters), error: nil)])
        return (model, preferences)
    }

    private func snapshot(_ meters: [AIUsageMeter]) -> AIUsageSnapshot {
        AIUsageSnapshot(providerID: "p", meters: meters, fetchedAt: Date(), source: "test fixture")
    }

    @MainActor
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor
    func testTheStripShowsTheMostUrgentLimitsAndAnOverflowCount() async {
        let (model, preferences) = setUp([
            .init(label: "Daily", used: 50, unit: .percent),
            .init(label: "Weekly", used: 97, unit: .percent),
            .init(label: "Monthly", used: 85, unit: .percent),
            .init(label: "Hourly", used: 99, unit: .percent),
        ])
        preferences.priorityMenuBar = true
        preferences.priorityCount = 1
        await settle()
        XCTAssertEqual(model.statusPins.map(\.label), ["p Hourly"])
        XCTAssertEqual(model.statusOverflow, 2, "Weekly and Monthly did not fit; Daily is not urgent")
        XCTAssertTrue(model.statusItemText.hasSuffix(" · +2"))

        preferences.priorityMenuBar = false
        await settle()
        XCTAssertEqual(model.statusOverflow, 0, "off: the starred metrics decide as before")
    }

    @MainActor
    func testACrossingPostsOneAlertOnlyWithTheSettingOn() async {
        let (model, preferences) = setUp([.init(label: "Weekly", used: 70, unit: .percent)])
        var posted: [String] = []
        model.postAlert = { title, body in posted.append("\(title) | \(body)") }

        model.apply([.init(providerID: "p", snapshot: snapshot([.init(label: "Weekly", used: 85, unit: .percent)]), error: nil)])
        XCTAssertEqual(posted, [], "alerts are off by default")

        preferences.quotaAlertsEnabled = true
        await settle()
        model.apply([.init(providerID: "p", snapshot: snapshot([.init(label: "Weekly", used: 96, unit: .percent)]), error: nil)])
        model.apply([.init(providerID: "p", snapshot: snapshot([.init(label: "Weekly", used: 97, unit: .percent)]), error: nil)])
        XCTAssertEqual(posted, ["AI limit nearly used up | p Weekly: 4% left"], "posted at the crossing, not repeated")
    }
}
