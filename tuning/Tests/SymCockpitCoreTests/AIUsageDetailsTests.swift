import XCTest
@testable import SymCockpitCore

/// #453/#454: the extras the agent passes through decode and read as caption lines.
final class AIUsageDetailsTests: XCTestCase {
    /// The agent's `ai-usage` output for these extras, as the Rust test
    /// `passes_plan_org_billing_reset_grants_and_accounts_through` asserts it.
    private let agentOutput = #"""
    [{"provider_id":"claude",
      "snapshot":{"provider_id":"claude","meters":[],"fetched_at":816861600.0,"source":"oauth","plan":"Max",
        "reset_grants":{"eligible":true,"next_grant_id":"g1",
          "grants":[{"id":"g1","resets_left":2,"ends_at":816879600.0,"clears":["Weekly"]}]}},
      "accounts":[{"label":"claude-1a2b3c4d","source":"claude_cli","state":"used"},
                  {"label":"claude-9f8e7d6c","source":"claude_desktop","state":"not_read","detail":"<redacted>"}]},
     {"provider_id":"copilot",
      "snapshot":{"provider_id":"copilot","meters":[],"fetched_at":816861600.0,"source":"api",
        "org_billing":{"state":"available","detail":"month to date","organization":"acme"}}}]
    """#

    func testTheAgentsExtrasDecodeAndReadAsCaptions() throws {
        let json = try JSONDecoder().decode(AgentJSON.self, from: Data(agentOutput.utf8))
        let results = try AgentDecoding.decode([AIUsageService.ProviderResult].self, from: json)
        let claude = try XCTUnwrap(results.first)
        XCTAssertEqual(claude.snapshot?.plan, "Max")
        XCTAssertEqual(claude.snapshot?.resetGrants?.nextGrantId, "g1")
        XCTAssertEqual(claude.accounts?.map(\.state), ["used", "not_read"])
        let now = Date(timeIntervalSinceReferenceDate: 816_861_600)
        XCTAssertEqual(
            AIUsageFormatting.detailLines(snapshot: claude.snapshot, accounts: claude.accounts ?? [], now: now),
            ["Plan: Max", "2 usage resets left (Weekly), expires in 5h 00m",
             "Reads login claude-1a2b3c4d (2 local logins found)"])
        let copilot = results[1]
        XCTAssertNil(copilot.accounts)
        XCTAssertEqual(AIUsageFormatting.detailLines(snapshot: copilot.snapshot, accounts: [], now: now),
                       ["Billed to organization acme"])
    }

    func testOtherStatesReadPlainly() {
        let snapshot = AIUsageSnapshot(providerID: "copilot", meters: [], source: "api")
        var withExtras = snapshot
        withExtras.orgBilling = AIUsageOrgBilling(state: "forbidden", detail: "needs an organization owner")
        withExtras.resetGrants = AIUsageResetGrants(eligible: false, grants: [])
        let unattributed = [AIUsageAccount(label: "unattributed", source: "oauth", state: "unattributed"),
                            AIUsageAccount(label: "claude-1", source: "claude_cli", state: "candidate")]
        XCTAssertEqual(
            AIUsageFormatting.detailLines(snapshot: withExtras, accounts: unattributed, now: Date()),
            ["Organization billing: needs an organization owner", "Usage resets: not eligible",
             "Login not attributed: 1 possible owner"])
        XCTAssertEqual(AIUsageFormatting.detailLines(snapshot: snapshot,
            accounts: [AIUsageAccount(label: "claude-1", source: "claude_cli", state: "used")], now: Date()), [],
            "a single login needs no line")
    }
}
