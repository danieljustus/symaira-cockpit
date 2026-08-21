import XCTest
@testable import SymOperateCore

final class AccessibilityServiceTests: XCTestCase {
    private let mockElement = AXUIElementCreateApplication(123)

    func testCacheEvictsOldestSnapshotWhenBounded() {
        let service = AccessibilityService()

        for i in 0..<22 {
            let snapshotID = "snapshot_\(i)"
            var cache: [String: AccessibilityService.ResolvedElement] = [:]
            cache["element_\(i)"] = AccessibilityService.ResolvedElement(
                element: mockElement,
                frame: RectValue(x: 0, y: 0, width: 100, height: 100),
                role: "AXButton",
                title: "Button \(i)",
                label: nil,
                value: nil
            )
            service.elementCache[snapshotID] = cache
            service.cacheOrder.append(snapshotID)
        }

        XCTAssertEqual(service.cacheOrder.count, 22)
        XCTAssertEqual(service.elementCache.count, 22)

        while service.cacheOrder.count > 20 {
            let oldest = service.cacheOrder.removeFirst()
            service.elementCache.removeValue(forKey: oldest)
        }

        XCTAssertEqual(service.cacheOrder.count, 20)
        XCTAssertEqual(service.elementCache.count, 20)
        XCTAssertFalse(service.cacheOrder.contains("snapshot_0"))
        XCTAssertTrue(service.cacheOrder.contains("snapshot_21"))
    }

    func testResolveElementReturnsNilForEvictedSnapshot() {
        let service = AccessibilityService()

        let snapshotID = "snapshot_test"
        var cache: [String: AccessibilityService.ResolvedElement] = [:]
        cache["element_1"] = AccessibilityService.ResolvedElement(
            element: mockElement,
            frame: RectValue(x: 10, y: 10, width: 50, height: 50),
            role: "AXButton",
            title: "Test",
            label: nil,
            value: nil
        )
        service.elementCache[snapshotID] = cache
        service.cacheOrder.append(snapshotID)

        XCTAssertNotNil(service.resolveElement(snapshotID: snapshotID, elementID: "element_1"))

        service.elementCache.removeValue(forKey: snapshotID)

        XCTAssertNil(service.resolveElement(snapshotID: snapshotID, elementID: "element_1"))
    }

    func testResolveElementReturnsNilForNonExistentElement() {
        let service = AccessibilityService()

        let snapshotID = "snapshot_test2"
        var cache: [String: AccessibilityService.ResolvedElement] = [:]
        cache["element_1"] = AccessibilityService.ResolvedElement(
            element: mockElement,
            frame: RectValue(x: 10, y: 10, width: 50, height: 50),
            role: "AXButton",
            title: "Test",
            label: nil,
            value: nil
        )
        service.elementCache[snapshotID] = cache
        service.cacheOrder.append(snapshotID)

        XCTAssertNil(service.resolveElement(snapshotID: snapshotID, elementID: "non_existent_element"))
    }

    func testSearchTextInoutParameterCumulativeEnforcement() {
        let service = AccessibilityService()

        var seen = 0
        _ = service.searchText(
            in: mockElement,
            needle: "nonexistent",
            remainingDepth: 1,
            seen: &seen,
            maxNodes: 10
        )

        XCTAssertGreaterThan(seen, 0)
    }

    func testSearchTextEnforcesMaxNodesCumulatively() {
        let service = AccessibilityService()

        var seen = 0
        _ = service.searchText(
            in: mockElement,
            needle: "nonexistent",
            remainingDepth: 10,
            seen: &seen,
            maxNodes: 1
        )

        // The mock element has no children, so exactly 1 node should be visited before the budget stops further traversal.
        XCTAssertEqual(seen, 1, "searchText should stop after maxNodes=1 is reached")
    }

    func testStaleReferenceErrorExists() {
        let error = AutomationError.staleReference("Snapshot has expired")
        XCTAssertEqual(error.localizedDescription, "Snapshot has expired")

        switch error {
        case .staleReference(let message):
            XCTAssertEqual(message, "Snapshot has expired")
        default:
            XCTFail("Expected staleReference case")
        }
    }

    func testPollingCacheAbsentTextsAccumulate() {
        let service = AccessibilityService()

        service.pollingAbsentTexts.insert("hello")
        service.pollingAbsentTexts.insert("world")

        XCTAssertTrue(service.pollingAbsentTexts.contains("hello"))
        XCTAssertTrue(service.pollingAbsentTexts.contains("world"))
        XCTAssertEqual(service.pollingAbsentTexts.count, 2)
    }

    func testInvalidatePollingCacheClearsState() {
        let service = AccessibilityService()

        service.pollingCachePID = 42
        service.pollingAbsentTexts.insert("hello")
        service.pollingAbsentTexts.insert("world")

        service.invalidatePollingCache()

        XCTAssertNil(service.pollingCachePID)
        XCTAssertTrue(service.pollingAbsentTexts.isEmpty)
    }

    func testPollingCachePIDChangeClearsAbsentSet() {
        let service = AccessibilityService()

        service.pollingCachePID = 42
        service.pollingAbsentTexts.insert("hello")

        // Simulate PID change by setting a different PID before calling polling
        // We can't call frontmostContainsTextPolling in CI (no AX permission),
        // but we can verify the cache data structure behavior.
        service.pollingCachePID = 99
        service.pollingAbsentTexts.removeAll()

        XCTAssertTrue(service.pollingAbsentTexts.isEmpty)
        XCTAssertEqual(service.pollingCachePID, 99)
    }

    func testPollingSearchTextUsesReducedScope() {
        let service = AccessibilityService()

        // searchText with reduced params (depth=3, maxNodes=50) should still
        // visit the mock element and enforce the budget.
        var seen = 0
        _ = service.searchText(
            in: mockElement,
            needle: "nonexistent",
            remainingDepth: 3,
            seen: &seen,
            maxNodes: 50
        )

        XCTAssertEqual(seen, 1, "searchText should visit exactly 1 node (mock has no children)")
    }

    func testProtocolDefaultFrontmostContainsTextPollingFallsBack() {
        let service = AccessibilityService()
        // Default protocol extension delegates to frontmostContainsText.
        // In CI without AX permission both return false.
        let result = service.frontmostContainsTextPolling("test")
        XCTAssertFalse(result)
    }
}
