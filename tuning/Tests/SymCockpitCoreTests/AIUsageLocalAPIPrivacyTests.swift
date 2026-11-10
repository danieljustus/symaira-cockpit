import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageLocalAPIPrivacyTests: XCTestCase {
    func testSecretCannotEscapeThroughEncodedResourceIdentity() throws {
        let secret = "sk-" + String(repeating: "x", count: 48)
        let label = "Bearer " + secret
        let request = Data("GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:6737\r\n\r\n".utf8)
        let response = AIUsageLocalAPI.route(header: request, port: 6737) {
            [.init(providerID: "p", snapshot: .init(providerID: "p", meters: [
                .init(label: label, used: 1, unit: .credits)
            ], source: "fixture"), error: "failed")]
        }
        XCTAssertEqual(response.status, 200)
        let text = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        let encoded = Data(label.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertFalse(text.contains(encoded), "Redact before encoding IDs, not only their display labels")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let providers = try XCTUnwrap(object["providers"] as? [String: [String: Any]])
        XCTAssertEqual(providers["p"]?["stale"] as? Bool, true)
    }
}
