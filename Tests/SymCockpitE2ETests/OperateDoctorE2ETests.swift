import XCTest

/// Doctor smoke test for the operate family through the unified dispatcher.
final class OperateDoctorE2ETests: XCTestCase {

    func testDoctorOutputsContainCapabilities() throws {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // Tests/SymCockpitE2ETests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let binary = repoRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("symcockpit")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["operate", "doctor"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("doctor did not emit valid JSON")
            return
        }

        XCTAssertNotNil(json["ok"], "Expected ok in doctor output")
        XCTAssertNotNil(json["capabilities"], "Expected capabilities in doctor output")
        XCTAssertNotNil(json["permissions"], "Expected permissions in doctor output")
        XCTAssertNotNil(json["recommendations"], "Expected recommendations in doctor output")

        if let capabilities = json["capabilities"] as? [String: Bool] {
            XCTAssertNotNil(capabilities["screenshot"])
            XCTAssertNotNil(capabilities["accessibility"])
        }
    }
}
