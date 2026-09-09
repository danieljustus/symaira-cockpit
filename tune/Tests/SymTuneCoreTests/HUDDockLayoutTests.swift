import XCTest
@testable import SymTuneCore

/// Geometry of the docked HUD.
///
/// The HUD can sit in the camera cutout or on either screen edge at one of
/// three heights, and a drag between those positions snaps to the nearest one.
/// All of that is arithmetic on numbers read off an `NSScreen`, so all of it is
/// checkable here — without a display, and without a running app.
final class HUDDockLayoutTests: XCTestCase {

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

    /// A 4K external: no cutout, no safe-area inset, but a menu bar strip.
    private func externalScreen(
        originX: CGFloat = 0,
        originY: CGFloat = 0
    ) -> NotchScreenMetrics {
        NotchScreenMetrics(
            frame: CGRect(x: originX, y: originY, width: 3840, height: 2160),
            menuBarHeight: 0,
            leftAuxiliaryWidth: nil,
            rightAuxiliaryWidth: nil
        )
    }

    // MARK: - Availability

    func testEveryDisplaySupportsBothEdgesAtEveryHeight() {
        // Arrange: the display that NotchLayout refuses outright.
        let external = externalScreen()

        // Act + assert: the edges are exactly what it can still host.
        for dock in HUDDock.edgeCases {
            XCTAssertTrue(
                HUDDockLayout.supports(dock, on: external),
                "expected \(dock.storageKey) to be available on an external display"
            )
        }
        XCTAssertFalse(HUDDockLayout.supports(.notch, on: external))
    }

    func testNotchIsSupportedOnlyWhereThereIsACutout() {
        XCTAssertTrue(HUDDockLayout.supports(.notch, on: notchedScreen()))
        XCTAssertFalse(HUDDockLayout.supports(.notch, on: externalScreen()))
    }

    func testNotchPreferenceFallsBackToTheRightEdgeWithoutACutout() {
        // Arrange: the lid-closed MacBook — the stored dock cannot be drawn.
        let external = externalScreen()

        // Act
        let effective = HUDDockLayout.effective(.notch, on: external)

        // Assert: a HUD the user can still see, not no HUD at all.
        XCTAssertEqual(effective, .right(.center))
    }

    func testASupportedDockIsKeptUnchanged() {
        let metrics = notchedScreen()
        XCTAssertEqual(HUDDockLayout.effective(.notch, on: metrics), .notch)
        XCTAssertEqual(HUDDockLayout.effective(.left(.bottom), on: metrics), .left(.bottom))
    }

    func testADisplayTooShortForAPillHostsNoEdgeDock() {
        // Arrange: a strip of a display with no room between the margins.
        var metrics = externalScreen()
        metrics.frame.size.height = HUDDockLayout.edgeCollapsedHeight

        // Act + assert
        XCTAssertNil(HUDDockLayout.usableBand(metrics))
        XCTAssertNil(HUDDockLayout.collapsedFrame(.right(.center), on: metrics))
        XCTAssertNil(HUDDockLayout.effective(.notch, on: metrics))
    }

    // MARK: - Edge placement

    func testEdgeDocksHangOnTheirOwnEdge() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let right = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)
        let left = HUDDockLayout.collapsedFrame(.left(.center), on: metrics)

        // Assert: one inset from each edge, and the widths agree.
        XCTAssertEqual(right?.maxX, metrics.frame.maxX - HUDDockLayout.edgeInset)
        XCTAssertEqual(left?.minX, metrics.frame.minX + HUDDockLayout.edgeInset)
        XCTAssertEqual(right?.width, HUDDockLayout.edgeCollapsedWidth)
        XCTAssertEqual(left?.width, HUDDockLayout.edgeCollapsedWidth)
    }

    func testEdgeDocksRespectAnOffsetDisplayOrigin() {
        // Arrange: a second display placed to the right of, and below, the main
        // one — global coordinates, not screen-local ones.
        let metrics = externalScreen(originX: 1512, originY: -400)

        // Act
        let frame = HUDDockLayout.collapsedFrame(.right(.top), on: metrics)

        // Assert
        XCTAssertEqual(frame?.maxX, metrics.frame.maxX - HUDDockLayout.edgeInset)
        XCTAssertTrue(metrics.frame.contains(frame!))
    }

    func testTheThreeSlotsAreOrderedTopToBottomAndDoNotOverlap() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let top = HUDDockLayout.collapsedFrame(.right(.top), on: metrics)!
        let centre = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!
        let bottom = HUDDockLayout.collapsedFrame(.right(.bottom), on: metrics)!

        // Assert: distinct, in order, and none of them touching.
        XCTAssertGreaterThan(top.minY, centre.maxY)
        XCTAssertGreaterThan(centre.minY, bottom.maxY)
    }

    func testEdgeDocksStayClearOfTheMenuBarAndTheScreenEnds() {
        // Arrange
        let metrics = notchedScreen()

        // Act + assert: every dock inside the display, and below the menu bar.
        for dock in HUDDock.edgeCases {
            let collapsed = HUDDockLayout.collapsedFrame(dock, on: metrics)!
            let expanded = HUDDockLayout.expandedFrame(dock, on: metrics)!
            for frame in [collapsed, expanded] {
                XCTAssertTrue(
                    metrics.frame.contains(frame),
                    "\(dock.storageKey) frame \(frame) left the display"
                )
                XCTAssertLessThanOrEqual(
                    frame.maxY,
                    metrics.frame.maxY - metrics.menuBarHeight,
                    "\(dock.storageKey) overlapped the menu bar"
                )
            }
        }
    }

    func testACollapsedEdgeDockIsFlushWithTheScreenEdge() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let right = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!
        let left = HUDDockLayout.collapsedFrame(.left(.center), on: metrics)!

        // Assert: no gap at all. A sliver with desktop behind it reads as a
        // small window; flush against the edge it reads as bezel.
        XCTAssertEqual(right.maxX, metrics.frame.maxX)
        XCTAssertEqual(left.minX, metrics.frame.minX)
    }

    func testAnExpandedEdgeCardStaysFlushWithTheEdgeItGrewFrom() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let collapsed = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!
        let expanded = HUDDockLayout.expandedFrame(.right(.center), on: metrics)!

        // Assert: it unfolds inward, and never peels off the edge.
        XCTAssertEqual(expanded.maxX, collapsed.maxX)
        XCTAssertLessThan(expanded.minX, collapsed.minX)
    }

    func testTheHoverStripIsWiderThanTheDrawnSliverButStillOnTheEdge() {
        // Arrange: seven points is a hard thing to hit deliberately and an easy
        // thing to cross by accident, so the reactive strip is wider.
        let metrics = notchedScreen()

        // Act
        let drawn = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!
        let hover = HUDDockLayout.hoverFrame(.right(.center), on: metrics)!

        // Assert
        XCTAssertGreaterThan(hover.width, drawn.width)
        XCTAssertEqual(hover.width, HUDDockLayout.edgeHoverWidth)
        XCTAssertEqual(hover.maxX, drawn.maxX, "the strip must grow inward, not off-screen")
        XCTAssertEqual(hover.minY, drawn.minY)
        XCTAssertEqual(hover.height, drawn.height)
        XCTAssertTrue(metrics.frame.contains(hover))
    }

    func testTheLeftHoverStripGrowsInwardToo() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let drawn = HUDDockLayout.collapsedFrame(.left(.top), on: metrics)!
        let hover = HUDDockLayout.hoverFrame(.left(.top), on: metrics)!

        // Assert: anchored on the left edge, so it is minX that is preserved.
        XCTAssertEqual(hover.minX, drawn.minX)
        XCTAssertEqual(hover.width, HUDDockLayout.edgeHoverWidth)
        XCTAssertTrue(metrics.frame.contains(hover))
    }

    func testTheNotchDockNeedsNoWiderHoverStrip() {
        // Arrange: the cutout HUD is already a comfortable target.
        let metrics = notchedScreen()

        // Act + assert
        XCTAssertEqual(
            HUDDockLayout.hoverFrame(.notch, on: metrics),
            HUDDockLayout.collapsedFrame(.notch, on: metrics)
        )
    }

    // MARK: - Expansion anchors

    func testExpansionKeepsTheAnchoredEdgeAndGrowsInward() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let topCollapsed = HUDDockLayout.collapsedFrame(.right(.top), on: metrics)!
        let topExpanded = HUDDockLayout.expandedFrame(.right(.top), on: metrics)!
        let bottomCollapsed = HUDDockLayout.collapsedFrame(.right(.bottom), on: metrics)!
        let bottomExpanded = HUDDockLayout.expandedFrame(.right(.bottom), on: metrics)!

        // Assert: the top dock keeps its top edge and grows down; the bottom
        // dock keeps its bottom edge and grows up. Anything else reads as the
        // card jumping rather than unfolding.
        XCTAssertEqual(topExpanded.maxY, topCollapsed.maxY, accuracy: 0.001)
        XCTAssertEqual(bottomExpanded.minY, bottomCollapsed.minY, accuracy: 0.001)
        XCTAssertGreaterThan(topExpanded.height, topCollapsed.height)
    }

    func testACentredDockGrowsBothWays() {
        // Arrange
        let metrics = notchedScreen()

        // Act
        let collapsed = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!
        let expanded = HUDDockLayout.expandedFrame(.right(.center), on: metrics)!

        // Assert
        XCTAssertEqual(expanded.midY, collapsed.midY, accuracy: 0.001)
        XCTAssertGreaterThan(expanded.height, collapsed.height)
    }

    func testAnExpandedCardIsClampedToTheBandRatherThanOverflowing() {
        // Arrange: a content height far taller than the display.
        let metrics = notchedScreen()

        // Act
        let expanded = HUDDockLayout.expandedFrame(
            .right(.center),
            on: metrics,
            contentHeight: 5000
        )!

        // Assert
        XCTAssertTrue(metrics.frame.contains(expanded))
        XCTAssertLessThanOrEqual(expanded.maxY, metrics.frame.maxY - metrics.menuBarHeight)
    }

    func testTheNotchDockStillDelegatesToNotchLayout() {
        // Arrange
        let metrics = notchedScreen()

        // Act + assert: one source of truth for the cutout geometry.
        XCTAssertEqual(
            HUDDockLayout.collapsedFrame(.notch, on: metrics),
            NotchLayout.collapsedFrame(metrics)
        )
        XCTAssertEqual(
            HUDDockLayout.expandedFrame(.notch, on: metrics),
            NotchLayout.expandedFrame(metrics)
        )
    }

    // MARK: - Snapping

    func testADragEndingOnADockSnapsToIt() {
        // Arrange
        let metrics = notchedScreen()
        let target = HUDDockLayout.collapsedFrame(.right(.bottom), on: metrics)!

        // Act
        let dock = HUDDockLayout.nearestDock(
            to: CGPoint(x: target.midX, y: target.midY),
            on: metrics
        )

        // Assert
        XCTAssertEqual(dock, .right(.bottom))
    }

    func testADragTowardsTheNotchSnapsToTheNotch() {
        // Arrange
        let metrics = notchedScreen()
        let notch = NotchLayout.collapsedFrame(metrics)!

        // Act
        let dock = HUDDockLayout.nearestDock(
            to: CGPoint(x: notch.midX, y: notch.midY),
            on: metrics
        )

        // Assert
        XCTAssertEqual(dock, .notch)
    }

    func testTheNotchIsNotOfferedOnADisplayWithoutACutout() {
        // Arrange: the point where the cutout would be on an external display.
        let metrics = externalScreen()
        let point = CGPoint(x: metrics.frame.midX, y: metrics.frame.maxY - 10)

        // Act
        let dock = HUDDockLayout.nearestDock(to: point, on: metrics)

        // Assert: anything but a dock that cannot be drawn here.
        XCTAssertNotEqual(dock, .notch)
    }

    func testADragEndingInEmptySpaceSnapsToNothing() {
        // Arrange: the middle of a large display, far from every edge.
        let metrics = externalScreen()

        // Act
        let dock = HUDDockLayout.nearestDock(
            to: CGPoint(x: metrics.frame.midX, y: metrics.frame.midY),
            on: metrics
        )

        // Assert: `nil`, so the caller can leave the HUD where it was instead
        // of flinging it to an edge the user never aimed at.
        XCTAssertNil(dock)
    }

    func testSnappingPrefersTheNearerOfTwoAdjacentSlots() {
        // Arrange: a point just below the centre dock, between it and bottom.
        let metrics = notchedScreen()
        let centre = HUDDockLayout.collapsedFrame(.right(.center), on: metrics)!

        // Act
        let dock = HUDDockLayout.nearestDock(
            to: CGPoint(x: centre.midX, y: centre.midY - 10),
            on: metrics
        )

        // Assert
        XCTAssertEqual(dock, .right(.center))
    }

    // MARK: - Persistence

    func testEveryDockRoundTripsThroughItsStorageKey() {
        for dock in HUDDock.allCases {
            XCTAssertEqual(
                HUDDock(storageKey: dock.storageKey),
                dock,
                "\(dock.storageKey) did not survive a round trip"
            )
        }
    }

    func testStorageKeysAreUnique() {
        let keys = HUDDock.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testAnUnknownStorageKeyIsRejectedRatherThanGuessed() {
        XCTAssertNil(HUDDock(storageKey: ""))
        XCTAssertNil(HUDDock(storageKey: "right"))
        XCTAssertNil(HUDDock(storageKey: "right.middle"))
        XCTAssertNil(HUDDock(storageKey: "diagonal.top"))
    }

    func testAllCasesCoversTheNotchAndBothEdgesAtEveryHeight() {
        XCTAssertEqual(HUDDock.allCases.count, 7)
        XCTAssertEqual(HUDDock.edgeCases.count, 6)
        XCTAssertTrue(HUDDock.allCases.contains(.notch))
    }

    // MARK: - The peek stage

    /// Peeking has to be visibly bigger than parked on every dock, or the
    /// pointer arriving produces no feedback at all.
    func testPeekingIsBiggerThanParkedEverywhere() {
        let metrics = notchedScreen()
        for dock in HUDDock.allCases {
            guard let parked = HUDDockLayout.collapsedFrame(dock, on: metrics),
                  let peeking = HUDDockLayout.peekFrame(dock, on: metrics)
            else {
                XCTFail("\(dock.storageKey) has no frames on a notched display")
                continue
            }
            XCTAssertGreaterThan(peeking.width, parked.width, "\(dock.storageKey) got no wider")
            XCTAssertGreaterThan(peeking.height, parked.height, "\(dock.storageKey) got no taller")
        }
    }

    /// And smaller than open, or the click that opens it would do nothing.
    func testPeekingIsSmallerThanOpenEverywhere() {
        let metrics = notchedScreen()
        for dock in HUDDock.allCases {
            guard let peeking = HUDDockLayout.peekFrame(dock, on: metrics),
                  let open = HUDDockLayout.expandedFrame(dock, on: metrics)
            else {
                XCTFail("\(dock.storageKey) has no frames on a notched display")
                continue
            }
            XCTAssertLessThan(peeking.width, open.width, "\(dock.storageKey) opened no wider")
            XCTAssertLessThan(peeking.height, open.height, "\(dock.storageKey) opened no taller")
        }
    }

    /// The peeking notch still has to be centred on the cutout and still has to
    /// leave the app's own menu title alone at the far left.
    func testThePeekingNotchStaysCentredOnTheCutoutAndInsideTheStrip() {
        let metrics = notchedScreen()
        guard let peeking = NotchLayout.peekFrame(metrics),
              let notch = NotchLayout.notchWidth(metrics),
              let left = metrics.leftAuxiliaryWidth
        else { return XCTFail("no peek frame") }

        let cutoutCentre = metrics.frame.minX + left + notch / 2
        XCTAssertEqual(peeking.midX, cutoutCentre, accuracy: 0.001)
        XCTAssertGreaterThan(peeking.minX, metrics.frame.minX, "the peek reached the screen edge")
        XCTAssertLessThan(peeking.maxX, metrics.frame.maxX, "the peek reached the screen edge")
        XCTAssertEqual(peeking.maxY, metrics.frame.maxY, accuracy: 0.001, "it came off the bezel")
    }

    /// On a display whose auxiliary strips are tight, the peek declines to grow
    /// rather than shrinking the readouts already on the shoulders.
    func testAPeekNeverNarrowsTheRestingShoulder() {
        for width in [CGFloat(1280), 1512, 1728, 3024] {
            let metrics = notchedScreen(width: width)
            guard let resting = NotchLayout.shoulderWidth(metrics),
                  let peeking = NotchLayout.peekShoulderWidth(metrics)
            else { continue }
            XCTAssertGreaterThanOrEqual(peeking, resting, "peek shrank the shoulder at \(width)")
        }
    }

    /// A display with no cutout has no notch peek — the same refusal
    /// `collapsedFrame` makes, for the same reason.
    func testAnExternalDisplayHasNoNotchPeek() {
        XCTAssertNil(NotchLayout.peekFrame(externalScreen()))
        XCTAssertNil(HUDDockLayout.peekFrame(.notch, on: externalScreen()))
        // Its edge docks still peek, which is what makes them worth having.
        XCTAssertNotNil(HUDDockLayout.peekFrame(.right(.center), on: externalScreen()))
    }

    // MARK: - Hit testing

    /// The region the stage accepts clicks in must never shrink as the HUD
    /// grows: the pointer that opened the HUD would otherwise find itself
    /// outside it and close it again on the next mouse-moved event.
    func testTheInteractiveRegionOnlyEverGrows() {
        for metrics in [notchedScreen(), externalScreen()] {
            for dock in HUDDock.allCases {
                guard let parked = HUDDockLayout.interactiveFrame(dock, on: metrics, presentation: .collapsed),
                      let peeking = HUDDockLayout.interactiveFrame(dock, on: metrics, presentation: .peek),
                      let open = HUDDockLayout.interactiveFrame(dock, on: metrics, presentation: .expanded)
                else { continue }
                XCTAssertTrue(peeking.contains(parked), "\(dock.storageKey): peek lost the parked region")
                XCTAssertTrue(open.contains(peeking), "\(dock.storageKey): open lost the peeking region")
            }
        }
    }

    /// Seven points is not something anybody aims at, so the parked edge dock's
    /// target stays wider than the sliver it draws — at every stage.
    func testAnEdgeDockIsAlwaysWiderToHitThanToSee() {
        let metrics = notchedScreen()
        for dock in HUDDock.edgeCases {
            for presentation in HUDPresentation.allCases {
                guard let drawn = HUDDockLayout.frame(dock, on: metrics, presentation: presentation),
                      let target = HUDDockLayout.interactiveFrame(dock, on: metrics, presentation: presentation)
                else { continue }
                XCTAssertGreaterThanOrEqual(target.width, drawn.width)
                XCTAssertGreaterThanOrEqual(target.width, HUDDockLayout.edgeHoverWidth)
                // Widened inward, never off the side of the display.
                XCTAssertGreaterThanOrEqual(target.minX, metrics.frame.minX)
                XCTAssertLessThanOrEqual(target.maxX, metrics.frame.maxX)
            }
        }
    }

    /// `frame(_:on:presentation:)` is the single entry point the view and the
    /// controller use; it has to agree with the three it dispatches to.
    func testTheFrameEntryPointAgreesWithEachStage() {
        let metrics = notchedScreen()
        for dock in HUDDock.allCases {
            XCTAssertEqual(
                HUDDockLayout.frame(dock, on: metrics, presentation: .collapsed),
                HUDDockLayout.collapsedFrame(dock, on: metrics)
            )
            XCTAssertEqual(
                HUDDockLayout.frame(dock, on: metrics, presentation: .peek),
                HUDDockLayout.peekFrame(dock, on: metrics)
            )
            XCTAssertEqual(
                HUDDockLayout.frame(dock, on: metrics, presentation: .expanded),
                HUDDockLayout.expandedFrame(dock, on: metrics)
            )
        }
    }
}
