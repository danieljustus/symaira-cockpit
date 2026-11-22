import AppKit
import SwiftUI
@testable import SymCockpitCore
import SymairaTheme
import XCTest
@testable import SymCockpitUI

/// The shared plan confirmation mounted in a passive native host, in both appearances: reviewing
/// (with entries, sizes and an expiry), expired, and finished with every kind of result. It runs
/// against the fake agent and a plan built by hand, never against a real agent or hardware.
/// Set `COCKPIT_PLAN_RENDER_DIR` to export the renders as PNG files.
@MainActor
final class PlanConfirmationRenderTests: XCTestCase {
    private var directory: URL!
    private var sessions: [AgentSession] = []

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tuning/Tests/SymCockpitCoreTests/Fixtures")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-render-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(_ scenario: String) async -> AgentSession {
        let session = AgentSession(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [Self.fixtureDirectory.appendingPathComponent("fake-agent.pl").path, scenario],
            environment: ["FAKE_AGENT_FIXTURES": Self.fixtureDirectory.appendingPathComponent("agent-fixtures.json").path],
            startTimeout: 10, requestTimeout: 5
        ))
        sessions.append(session)
        await session.start()
        return session
    }

    private func plan(_ items: Int, received: Date = Date()) -> AgentPlan {
        AgentPlan(command: "plan_clean", planID: "pl_render", plan: .object([
            "expires_in_s": .number(300),
            "items": .array((0..<items).map {
                .object([
                    "target": .string("/Users/example/Library/Caches/com.example.app-\($0)/very/long/path/that/needs/truncating"),
                    "bytes": .number(Double(($0 + 1) * 1_500_000)),
                ])
            }),
        ]), received: received)
    }

    func testReviewExpiredAndResultStatesRenderInBothAppearances() async throws {
        let idle = await session("ok")
        let review = PlanConfirmationModel(plan: plan(9), session: idle)
        let expired = PlanConfirmationModel(plan: plan(2, received: Date().addingTimeInterval(-400)), session: idle)

        let mixedSession = await session("confirm_mixed")
        guard case .needsConfirmation(let mixedPlan) = await mixedSession.perform("fan.profile", params: ["profile": .string("comfort")]) else {
            return XCTFail("the fake plans fan.profile")
        }
        let mixed = PlanConfirmationModel(plan: mixedPlan, session: mixedSession)
        await mixed.confirm()
        XCTAssertEqual(mixed.report?.items.count, 3)

        guard case .needsConfirmation(let okPlan) = await idle.perform("fan.profile", params: ["profile": .string("comfort")]) else {
            return XCTFail("the fake plans fan.profile")
        }
        let done = PlanConfirmationModel(plan: okPlan, session: idle)
        await done.confirm()
        XCTAssertEqual(done.report?.status, .confirmed)

        for scheme in [ColorScheme.light, .dark] {
            for (name, model) in [("review", review), ("expired", expired), ("mixed", mixed), ("done", done)] {
                let view = PlanConfirmationView(model: model, summary: "Clean 9 caches.", confirmTitle: "Clean Caches", onClose: {})
                    .padding(20)
                    .frame(width: 520)
                    .background(SymairaTokens.canvas)
                    .environment(\.tunePanelChrome, .embedded)
                try await render(view, name: "plan-\(name)-\(scheme == .dark ? "dark" : "light")", scheme: scheme)
            }
        }
    }

    private func render<Content: View>(_ content: Content, name: String, scheme: ColorScheme) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let height = host.fittingSize.height
        host.frame = CGRect(x: 0, y: 0, width: 520, height: height)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(height, 60, "the view has content: \(name)")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), name)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name)
        XCTAssertGreaterThan(png.count, 4_000, "blank native render: \(name)")
        XCTAssertEqual(host.bounds.width, 520, "content exceeded the intended width: \(name)")
        if let folder = ProcessInfo.processInfo.environment["COCKPIT_PLAN_RENDER_DIR"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
