import AppKit
import SwiftUI
import XCTest
import SymCockpitCore
@testable import SymCockpitUI

final class AIUsageExportTests: XCTestCase {
    @MainActor
    func testShareRendersPNGWithoutFetchingOrTouchingClipboard() throws {
        _ = NSApplication.shared
        let snapshot = AIUsageSnapshot(providerID: "codex", meters: [
            .init(label: "Session", used: 42, limit: 100, unit: .percent),
            .init(label: "Weekly", used: 20, limit: 100, unit: .percent)
        ], source: "test fixture, not live usage")
        let row = AIUsageRow(providerID: "codex", displayName: "Fixture usage (not live)", snapshot: snapshot,
                             error: nil, lastSuccessAt: snapshot.fetchedAt, history: [])
        let card = AIUsageShareCard(row: row, metrics: AIUsageMetric.metrics(snapshot: snapshot),
                                    layout: AIUsageLayout(), now: snapshot.fetchedAt)
        let changeCount = NSPasteboard.general.changeCount
        for appearance in [ColorScheme.light, .dark] {
            let data = try XCTUnwrap(card.png(appearance: appearance))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 840)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
            if let directory = ProcessInfo.processInfo.environment["SYMTUNE_TEST_USAGE_EXPORT_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("usage-share-\(appearance == .dark ? "dark" : "light").png"))
            }
        }
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    func testProviderLinksAreHTTPSAndContainNoAuthentication() {
        for id in ["claude", "codex", "copilot", "cursor", "devin", "grok", "ollama", "opencode", "openrouter", "zai"] {
            let links = AIUsageProviderLink.links(for: id)
            XCTAssertFalse(links.isEmpty, id)
            for link in links {
                XCTAssertEqual(link.url.scheme, "https")
                XCTAssertNil(link.url.user)
                XCTAssertNil(link.url.password)
            }
        }
        XCTAssertTrue(AIUsageProviderLink.links(for: "unknown").isEmpty)
    }
}
