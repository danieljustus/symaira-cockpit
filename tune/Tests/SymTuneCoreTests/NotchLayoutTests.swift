import XCTest
@testable import SymTuneCore

/// Geometry of the notch HUD (issue #224).
///
/// The panel is placed by arithmetic on numbers the controller reads off an
/// `NSScreen`, so every rule that keeps it out of trouble — no HUD without a
/// cutout, bounded shoulders, expansion centred on the cutout and clamped to
/// the display — is checkable without a screen, and checked here.
final class NotchLayoutTests: XCTestCase {

    /// A 14" MacBook Pro in points: 1512×982, 37pt menu bar, ~200pt cutout.
    private func notchedScreen(
        width: CGFloat = 1512,
        height: CGFloat = 982,
        menuBar: CGFloat = 37,
        notch: CGFloat = 200,
        originX: CGFloat = 0,
        originY: CGFloat = 0
    ) -> NotchScreenMetrics {
        let side = (width - notch) / 2
        return NotchScreenMetrics(
            frame: CGRect(x: originX, y: originY, width: width, height: height),
            menuBarHeight: menuBar,
            leftAuxiliaryWidth: side,
            rightAuxiliaryWidth: side
        )
    }

    // MARK: - Notch detection

    func testExternalDisplayHasNoNotchAndNoHUD() {
        // Arrange: a 4K external — no safe-area inset, no auxiliary areas.
        let external = NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            menuBarHeight: 0,
            leftAuxiliaryWidth: nil,
            rightAuxiliaryWidth: nil
        )

        // Act + assert: nothing is offered for a display without a cutout.
        XCTAssertNil(NotchLayout.notchWidth(external))
        XCTAssertFalse(NotchLayout.supportsHUD(external))
        XCTAssertNil(NotchLayout.collapsedFrame(external))
        XCTAssertNil(NotchLayout.expandedFrame(external))
    }

    func testAuxiliaryAreasWithoutSafeAreaInsetDoNotCount() {
        // Arrange: auxiliary widths present but no menu-bar inset — not a
        // notched display, and the HUD must not guess otherwise.
        var metrics = notchedScreen()
        metrics.menuBarHeight = 0

        // Act + assert
        XCTAssertNil(NotchLayout.notchWidth(metrics))
    }

    func testAuxiliaryAreasCoveringTheFullWidthLeaveNoCutout() {
        // Arrange: the two strips already account for the whole width.
        var metrics = notchedScreen()
        metrics.leftAuxiliaryWidth = 756
        metrics.rightAuxiliaryWidth = 756

        // Act + assert: no cutout between them, so no HUD.
        XCTAssertNil(NotchLayout.notchWidth(metrics))
        XCTAssertFalse(NotchLayout.supportsHUD(metrics))
    }

    func testNotchWidthIsWhatTheAuxiliaryAreasLeaveOver() {
        // Arrange
        let metrics = notchedScreen(notch: 200)

        // Act + assert
        XCTAssertEqual(NotchLayout.notchWidth(metrics), 200)
    }

    // MARK: - Shoulders

    func testShoulderIsCappedByTheShareOfTheAuxiliaryStrip() {
        // Arrange: a cutout so wide the strips beside it are only 100pt.
        let metrics = notchedScreen(width: 1000, notch: 800)

        // Act
        let shoulder = NotchLayout.shoulderWidth(metrics)

        // Assert: 40% of 100pt, not the preferred 86pt — the rest of the strip
        // belongs to the menu titles and status items already there.
        XCTAssertEqual(shoulder, 40)
    }

    func testShoulderPrefersItsOwnWidthWhenTheStripIsRoomy() {
        // Arrange: a normal 14" — 656pt per side, 40% of which is plenty.
        let metrics = notchedScreen()

        // Act + assert: capped at the preferred width, not the budget.
        XCTAssertEqual(NotchLayout.shoulderWidth(metrics), NotchLayout.preferredShoulder)
    }

    func testTooNarrowAStripDisablesTheHUDEntirely() {
        // Arrange: 40% of 60pt is 24pt — under the minimum a readout needs.
        let metrics = notchedScreen(width: 1000, notch: 880)

        // Act + assert: no shoulder means no panel at all, rather than a panel
        // whose content cannot fit beside the cutout.
        XCTAssertNil(NotchLayout.shoulderWidth(metrics))
        XCTAssertNil(NotchLayout.collapsedFrame(metrics))
        XCTAssertFalse(NotchLayout.supportsHUD(metrics))
    }

    // MARK: - Collapsed frame

    func testCollapsedFrameSpansTheCutoutPlusBothShoulders() {
        // Arrange
        let metrics = notchedScreen()
        let shoulder = NotchLayout.preferredShoulder

        // Act
        let frame = NotchLayout.collapsedFrame(metrics)

        // Assert: exactly the cutout plus one shoulder each side, filling the
        // menu bar strip at the top edge.
        XCTAssertEqual(frame?.width, 200 + shoulder * 2)
        XCTAssertEqual(frame?.height, 37)
        XCTAssertEqual(frame?.minX, 656 - shoulder)
        XCTAssertEqual(frame?.maxY, 982)
    }

    func testCollapsedFrameFollowsTheScreenOrigin() {
        // Arrange: the notched display sits right of and above the origin, as
        // it does whenever an external monitor is arranged to its left.
        let metrics = notchedScreen(originX: 3840, originY: 400)

        // Act
        let frame = NotchLayout.collapsedFrame(metrics)

        // Assert: the frame is global, not screen-relative.
        XCTAssertEqual(frame?.minX, 3840 + 656 - NotchLayout.preferredShoulder)
        XCTAssertEqual(frame?.maxY, 400 + 982)
    }

    // MARK: - Expanded frame

    func testExpandedCardIsCentredOnTheCutout() {
        // Arrange: an off-centre cutout, so centring on the screen and centring
        // on the cutout give different answers.
        var metrics = notchedScreen(notch: 200)
        metrics.leftAuxiliaryWidth = 400
        metrics.rightAuxiliaryWidth = 912

        // Act
        let frame = NotchLayout.expandedFrame(metrics)

        // Assert: centred on the cutout at x=500.
        XCTAssertEqual(frame?.midX, 500)
        XCTAssertEqual(frame?.width, NotchLayout.preferredExpandedWidth)
    }

    func testExpandedCardHangsFromTheTopEdgeAndAddsTheMenuBarStrip() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let frame = NotchLayout.expandedFrame(metrics, contentHeight: 200)

        // Assert: menu bar strip plus content, anchored at the top edge.
        XCTAssertEqual(frame?.height, 237)
        XCTAssertEqual(frame?.maxY, 982)
    }

    func testExpandedCardIsNeverNarrowerThanTheCollapsedPanel() {
        // Arrange: a cutout wider than the card's preferred width, so the
        // collapsed panel is the larger of the two.
        let metrics = notchedScreen(width: 1200, notch: 600)
        let collapsed = NotchLayout.collapsedFrame(metrics)

        // Act
        let expanded = NotchLayout.expandedFrame(metrics)

        // Assert: expanding must never shrink the panel — that would read as a
        // glitch rather than an expansion.
        XCTAssertEqual(expanded?.width, collapsed?.width)
        XCTAssertGreaterThan(expanded!.width, NotchLayout.preferredExpandedWidth)
    }

    func testExpandedCardStaysInsideTheScreenMargins() {
        // Arrange: cutout hard against the right edge, so a card centred on it
        // would hang off the display.
        var metrics = notchedScreen(width: 800, notch: 75)
        metrics.leftAuxiliaryWidth = 650
        metrics.rightAuxiliaryWidth = 75

        // Act
        let frame = NotchLayout.expandedFrame(metrics)

        // Assert: clamped to the margin instead.
        XCTAssertNotNil(frame)
        XCTAssertLessThanOrEqual(frame!.maxX, 800 - NotchLayout.screenMargin)
        XCTAssertGreaterThanOrEqual(frame!.minX, NotchLayout.screenMargin)
    }

    func testExpandedCardIsNeverTallerThanTheScreen() {
        // Arrange: a content height larger than the display itself.
        let metrics = notchedScreen(height: 400)

        // Act
        let frame = NotchLayout.expandedFrame(metrics, contentHeight: 5000)

        // Assert
        XCTAssertEqual(frame?.height, 400)
        XCTAssertEqual(frame?.minY, 0)
    }
}
