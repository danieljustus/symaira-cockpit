import XCTest
@testable import SymTuneCore

final class DisplayServiceTests: XCTestCase {
    func testNoScreensReportsEmptyList() {
        let source = FakeDisplayEnumerationSource(screens: [])
        let service = DisplayService(enumeration: source)
        let report = service.list()

        XCTAssertTrue(report.displays.isEmpty)
        XCTAssertEqual(report.notes.first, "No displays reported — symtune must run inside a logged-in GUI session.")
    }

    func testEDRDetection() {
        let source = FakeDisplayEnumerationSource(screens: [
            ScreenSnapshot(
                name: "External",
                displayID: 1,
                isBuiltin: false,
                maxEDRHeadroom: 1.0,
                potentialEDRHeadroom: 1.5,
                backingScaleFactor: 1.0
            )
        ])
        let service = DisplayService(enumeration: source)

        XCTAssertTrue(service.anyEDRCapable())
        let report = service.list()
        XCTAssertEqual(report.displays.first?.edrCapable, true)
    }

    func testNoBuiltInDisplayThrowsUnsupported() {
        let source = FakeDisplayEnumerationSource(screens: [
            ScreenSnapshot(
                name: "External",
                displayID: 1,
                isBuiltin: false,
                maxEDRHeadroom: 1.0,
                potentialEDRHeadroom: 1.0,
                backingScaleFactor: 1.0
            )
        ])
        let service = DisplayService(enumeration: source)

        XCTAssertThrowsError(try service.getBuiltinBrightness()) { error in
            guard case TuneError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    func testBuiltInDisplayFound() {
        let source = FakeDisplayEnumerationSource(screens: [
            ScreenSnapshot(
                name: "Built-in",
                displayID: 2,
                isBuiltin: true,
                maxEDRHeadroom: 1.0,
                potentialEDRHeadroom: 1.0,
                backingScaleFactor: 2.0
            )
        ])
        let service = DisplayService(enumeration: source)
        let report = service.list()

        XCTAssertEqual(report.displays.count, 1)
        XCTAssertEqual(report.displays.first?.name, "Built-in")
        XCTAssertEqual(report.displays.first?.isBuiltin, true)
        XCTAssertEqual(report.displays.first?.backingScaleFactor, 2.0)
    }
}
