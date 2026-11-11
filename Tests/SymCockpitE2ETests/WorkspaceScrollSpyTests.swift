import XCTest
@testable import SymCockpitUI

/// The workspace sidebar follows scrolling: the selected entry is the section
/// the reader is in, not only the last one clicked.
final class WorkspaceScrollSpyTests: XCTestCase {
    private let tops: [TuneWorkspaceAnchor: CGFloat] = [
        .overview: -900, .display: -400, .power: 60, .activity: 700, .readout: 1300,
    ]

    func testSelectsTheLastSectionWhoseTopPassedTheThreshold() {
        XCTAssertEqual(TuneWorkspaceAnchor.current(sectionTops: tops, threshold: 120, atBottom: false), .power)
        XCTAssertEqual(TuneWorkspaceAnchor.current(sectionTops: tops, threshold: 40, atBottom: false), .display)
    }

    func testAtTheTopTheFirstSectionIsSelected() {
        let atTop: [TuneWorkspaceAnchor: CGFloat] = [.overview: 24, .display: 500, .power: 1100]
        XCTAssertEqual(TuneWorkspaceAnchor.current(sectionTops: atTop, threshold: 10, atBottom: false), .overview)
    }

    func testAtTheBottomTheLastSectionWinsEvenIfItCannotReachTheTop() {
        XCTAssertEqual(TuneWorkspaceAnchor.current(sectionTops: tops, threshold: 120, atBottom: true), .readout)
    }

    func testNothingMeasuredSelectsNothing() {
        XCTAssertNil(TuneWorkspaceAnchor.current(sectionTops: [:], threshold: 120, atBottom: true))
    }
}
