import XCTest
import Foundation
@testable import SymTuneCore

// MARK: - Mock NetworkService

final class MockNetworkService: NetworkServiceProtocol, @unchecked Sendable {
    var responseData: Data?
    var response: URLResponse?
    var error: Error?

    func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        if let error = error { throw error }
        guard let data = responseData, let response = response else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

// MARK: - UpdateChecker Network Tests

final class UpdateCheckerNetworkTests: XCTestCase {
    private var mock: MockNetworkService!
    private let currentVersion = "0.1.0"

    override func setUp() {
        super.setUp()
        mock = MockNetworkService()
        Task { await UpdateChecker.resetCache() }
    }

    private func makeResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/danieljustus/symaira-tune/releases/latest")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func makeReleaseJSON(tagName: String, htmlURL: String? = nil) -> Data? {
        var json: [String: Any] = ["tag_name": tagName]
        if let htmlURL { json["html_url"] = htmlURL }
        return try? JSONSerialization.data(withJSONObject: json)
    }

    func testCheckForUpdateReturnsNewerVersion() async {
        mock.responseData = makeReleaseJSON(tagName: "v0.2.0", htmlURL: "https://github.com/example/releases/v0.2.0")
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertTrue(info!.updateAvailable)
        XCTAssertEqual(info!.latestVersion, "v0.2.0")
        XCTAssertEqual(info!.downloadURL, "https://github.com/example/releases/v0.2.0")
    }

    func testCheckForUpdateReturnsOlderVersion() async {
        mock.responseData = makeReleaseJSON(tagName: "v0.0.1")
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
        XCTAssertEqual(info!.latestVersion, "v0.0.1")
    }

    func testCheckForUpdateReturnsSameVersion() async {
        mock.responseData = makeReleaseJSON(tagName: "v0.1.0")
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
    }

    func testCheckForUpdateHandlesNetworkError() async {
        mock.error = URLError(.notConnectedToInternet)

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
        XCTAssertEqual(info!.latestVersion, currentVersion)
    }

    func testCheckForUpdateHandlesNon200Status() async {
        mock.responseData = makeReleaseJSON(tagName: "v0.2.0")
        mock.response = makeResponse(statusCode: 403)

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
    }

    func testCheckForUpdateHandlesInvalidJSON() async {
        mock.responseData = "not json".data(using: .utf8)
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
    }

    func testCheckForUpdateHandlesMissingTagName() async {
        mock.responseData = try? JSONSerialization.data(withJSONObject: ["name": "release"])
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
    }

    func testCheckForUpdateHandlesInvalidTagName() async {
        mock.responseData = makeReleaseJSON(tagName: "not-a-version")
        mock.response = makeResponse()

        let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.updateAvailable)
    }

    func testCheckForUpdateCachesResult() async {
        mock.responseData = makeReleaseJSON(tagName: "v0.2.0")
        mock.response = makeResponse()

        let info1 = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)
        let info2 = await UpdateChecker.checkForUpdate(currentVersion: currentVersion, networkService: mock)

        XCTAssertEqual(info1?.latestVersion, info2?.latestVersion)
    }
}
