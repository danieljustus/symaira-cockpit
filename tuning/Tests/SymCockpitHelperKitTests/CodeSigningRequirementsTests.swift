import SymCockpitCore
import XCTest
@testable import SymCockpitHelperKit

private struct FakeValidator: CodeRequirementValidating {
    var accepts: Bool
    var seen: SeenBox?
    func satisfies(requirement: String) -> Bool {
        seen?.requirements.append(requirement)
        return accepts
    }
}

private final class SeenBox: @unchecked Sendable { var requirements: [String] = [] }

private final class FakeConnection: XPCRequirementApplying {
    var applied: [String] = []
    func applyCodeSigningRequirement(_ requirement: String) { applied.append(requirement) }
}

final class CodeSigningRequirementsTests: XCTestCase {
    private let team = "ABCDE12345"

    func testTeamIdentifierValidation() {
        XCTAssertTrue(CodeSigningRequirements.isValidTeamIdentifier("ABCDE12345"))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier(""))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier("abcde12345"))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier("ABCDE1234"))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier("ABCDE123456"))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier("ABCDE1234\""))
        XCTAssertFalse(CodeSigningRequirements.isValidTeamIdentifier("ABCDE 1234"))
    }

    func testAppRequirementPinsAppIdentityAndTeam() throws {
        let requirement = try XCTUnwrap(CodeSigningRequirements.appRequirement(teamID: team))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("identifier \"com.symaira.cockpit\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertFalse(requirement.contains("com.symaira.symtune-helper"))
    }

    func testHelperRequirementPinsHelperIdentityAndTeam() throws {
        let requirement = try XCTUnwrap(CodeSigningRequirements.helperRequirement(teamID: team))
        XCTAssertTrue(requirement.contains("identifier \"com.symaira.symtune-helper\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertFalse(requirement.contains("\"com.symaira.cockpit\""))
    }

    func testRequirementsRefuseMalformedTeamIdentifiers() {
        let injected = "ABCDE12345\" or anchor apple"
        XCTAssertNil(CodeSigningRequirements.appRequirement(teamID: injected))
        XCTAssertNil(CodeSigningRequirements.helperRequirement(teamID: ""))
    }

    func testRequirementsExcludeHardenedRuntimeEscapeEntitlements() throws {
        let requirement = try XCTUnwrap(CodeSigningRequirements.appRequirement(teamID: team))
        for entitlement in CodeSigningRequirements.forbiddenEntitlements {
            XCTAssertTrue(requirement.contains("!entitlement[\"\(entitlement)\"] exists"), entitlement)
        }
        XCTAssertEqual(CodeSigningRequirements.forbiddenEntitlements.count, 4)
    }

    /// Catches requirement-language typos that would otherwise surface only
    /// as every connection being refused on a signed build.
    func testRequirementsCompileInTheSecurityFramework() throws {
        let app = try XCTUnwrap(CodeSigningRequirements.appRequirement(teamID: team))
        let helper = try XCTUnwrap(CodeSigningRequirements.helperRequirement(teamID: team))
        XCTAssertTrue(CodeSignatureInspector.isWellFormed(requirement: app))
        XCTAssertTrue(CodeSignatureInspector.isWellFormed(requirement: helper))
        XCTAssertFalse(CodeSignatureInspector.isWellFormed(requirement: "this is (not a requirement"))
    }

    // MARK: - Decision function

    func testHelperAcceptsAndAppliesTheAppRequirement() throws {
        let connection = FakeConnection()
        let seen = SeenBox()
        let accepted = FanHelperConnectionPolicy.secure(
            connection, role: .helperAcceptingApp, ownTeamID: team, embeddedTeamID: team,
            selfValidator: FakeValidator(accepts: true, seen: seen)
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(connection.applied, [try XCTUnwrap(CodeSigningRequirements.appRequirement(teamID: team))])
        // It checked its own signature against the *helper* requirement.
        XCTAssertEqual(seen.requirements, [try XCTUnwrap(CodeSigningRequirements.helperRequirement(teamID: team))])
    }

    func testAppAcceptsAndAppliesTheHelperRequirement() throws {
        let connection = FakeConnection()
        let seen = SeenBox()
        let accepted = FanHelperConnectionPolicy.secure(
            connection, role: .appAcceptingHelper, ownTeamID: team, embeddedTeamID: team,
            selfValidator: FakeValidator(accepts: true, seen: seen)
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(connection.applied, [try XCTUnwrap(CodeSigningRequirements.helperRequirement(teamID: team))])
        XCTAssertEqual(seen.requirements, [try XCTUnwrap(CodeSigningRequirements.appRequirement(teamID: team))])
    }

    func testUnsignedBinaryRejectsEveryConnection() {
        let connection = FakeConnection()
        for role in [FanHelperPeerRole.helperAcceptingApp, .appAcceptingHelper] {
            XCTAssertFalse(FanHelperConnectionPolicy.secure(
                connection, role: role, ownTeamID: nil, embeddedTeamID: team,
                selfValidator: FakeValidator(accepts: true)
            ))
        }
        XCTAssertTrue(connection.applied.isEmpty, "a refused connection must not get a requirement applied")
    }

    func testOwnSignatureThatFailsTheRequirementRejects() {
        let connection = FakeConnection()
        let decision = FanHelperConnectionPolicy.decide(
            role: .helperAcceptingApp, ownTeamID: team, embeddedTeamID: team,
            selfValidator: FakeValidator(accepts: false)
        )
        guard case .reject = decision else { return XCTFail("expected reject, got \(decision)") }
        XCTAssertFalse(FanHelperConnectionPolicy.secure(
            connection, role: .helperAcceptingApp, ownTeamID: team, embeddedTeamID: team,
            selfValidator: FakeValidator(accepts: false)
        ))
        XCTAssertTrue(connection.applied.isEmpty)
    }

    func testMalformedOwnTeamIdentifierRejects() {
        let decision = FanHelperConnectionPolicy.decide(
            role: .appAcceptingHelper, ownTeamID: "not-a-team", embeddedTeamID: team,
            selfValidator: FakeValidator(accepts: true)
        )
        guard case .reject = decision else { return XCTFail("expected reject, got \(decision)") }
    }

    func testRealSelfValidatorRejectsAnUnsignedTestRunner() {
        // The test bundle is never Developer-ID signed with the Cockpit team:
        // the real validator must say no rather than throw or crash.
        let requirement = CodeSigningRequirements.appRequirement(teamID: team) ?? ""
        XCTAssertFalse(SelfCodeRequirementValidator().satisfies(requirement: requirement))
    }

    // MARK: - Embedded team identifier (F4)

    func testBuildWithoutAnEmbeddedTeamNeverServesOrConnects() {
        let connection = FakeConnection()
        for role in [FanHelperPeerRole.helperAcceptingApp, .appAcceptingHelper] {
            XCTAssertFalse(FanHelperConnectionPolicy.secure(
                connection, role: role, ownTeamID: team, embeddedTeamID: nil,
                selfValidator: FakeValidator(accepts: true)
            ), "\(role)")
        }
        XCTAssertTrue(connection.applied.isEmpty)
    }

    func testRuntimeTeamThatDiffersFromTheEmbeddedOneIsRejectedOnBothSides() {
        let connection = FakeConnection()
        for role in [FanHelperPeerRole.helperAcceptingApp, .appAcceptingHelper] {
            let decision = FanHelperConnectionPolicy.decide(
                role: role, ownTeamID: "ZZZZZ99999", embeddedTeamID: team,
                selfValidator: FakeValidator(accepts: true)
            )
            guard case .reject = decision else { return XCTFail("\(role): \(decision)") }
            XCTAssertFalse(FanHelperConnectionPolicy.secure(
                connection, role: role, ownTeamID: "ZZZZZ99999", embeddedTeamID: team,
                selfValidator: FakeValidator(accepts: true)
            ))
        }
        XCTAssertTrue(connection.applied.isEmpty)
    }

    func testMalformedEmbeddedTeamIsRejected() {
        let decision = FanHelperConnectionPolicy.decide(
            role: .helperAcceptingApp, ownTeamID: team, embeddedTeamID: "abc",
            selfValidator: FakeValidator(accepts: true)
        )
        guard case .reject = decision else { return XCTFail("\(decision)") }
    }

    /// The committed constant must stay nil: a real team id is written only by
    /// scripts/build-app.sh from the signing identity, never committed.
    func testTheCommittedEmbeddedTeamIsNil() {
        XCTAssertNil(EmbeddedTeamIdentifier.value)
        XCTAssertNil(FanHelperClient.detectSigning().teamIDForTests)
    }

    func testDetectSigningNeedsEmbeddedAndMatchingTeam() {
        XCTAssertEqual(FanHelperClient.detectSigning(embeddedTeamID: nil), .unsigned)
        XCTAssertEqual(FanHelperClient.detectSigning(embeddedTeamID: team), .unsigned,
                       "the unsigned test runner has no matching signature")
    }
}

private extension FanHelperSigning {
    var teamIDForTests: String? {
        if case .releaseSigned(let id) = self { return id }
        return nil
    }
}
