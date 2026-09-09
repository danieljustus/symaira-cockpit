import XCTest
@testable import SymTuneCore

/// What the HUD shows, where, and how far it has to be open before it does.
///
/// Two things are worth the tests here. The **visibility rule** — an item shows
/// once the HUD has opened at least as far as the stage it was given — is one
/// comparison that every readout on screen depends on. And the **storage
/// round-trip** is the only thing standing between a user's configuration and a
/// silent reset on the next launch.
final class HUDItemLayoutTests: XCTestCase {

    // MARK: - Stage ordering

    func testPresentationsAreOrderedFromParkedToOpen() {
        XCTAssertLessThan(HUDPresentation.collapsed, .peek)
        XCTAssertLessThan(HUDPresentation.peek, .expanded)
        XCTAssertFalse(HUDPresentation.collapsed.isOpen)
        XCTAssertTrue(HUDPresentation.peek.isOpen)
        XCTAssertTrue(HUDPresentation.expanded.isOpen)
    }

    // MARK: - Visibility

    /// An item placed at a stage stays visible in every wider one. Anything
    /// else and a readout would blink out as the user opened the HUD further,
    /// which is the opposite of what opening it is for.
    func testAnItemStaysVisibleOnceItsStageIsReached() {
        for stage in HUDPresentation.allCases {
            var layout = HUDItemLayout()
            layout.set(
                HUDItemPlacement(isEnabled: true, side: .left, stage: stage),
                for: .metric(.cpu)
            )

            for presentation in HUDPresentation.allCases {
                let visible = layout.items(on: .left, at: presentation)
                if presentation >= stage {
                    XCTAssertEqual(visible, [.metric(.cpu)], "\(stage) missing at \(presentation)")
                } else {
                    XCTAssertTrue(visible.isEmpty, "\(stage) showed too early at \(presentation)")
                }
            }
        }
    }

    func testADisabledItemNeverShows() {
        var layout = HUDItemLayout()
        layout.set(
            HUDItemPlacement(isEnabled: false, side: .left, stage: .collapsed),
            for: .metric(.cpu)
        )
        for presentation in HUDPresentation.allCases {
            XCTAssertTrue(layout.items(at: presentation).isEmpty)
        }
    }

    func testItemsAreSplitBySide() {
        var layout = HUDItemLayout()
        layout.set(HUDItemPlacement(isEnabled: true, side: .left, stage: .collapsed), for: .metric(.cpu))
        layout.set(HUDItemPlacement(isEnabled: true, side: .right, stage: .collapsed), for: .battery)

        XCTAssertEqual(layout.items(on: .left, at: .collapsed), [.metric(.cpu)])
        XCTAssertEqual(layout.items(on: .right, at: .collapsed), [.battery])
        // Both sides, left first.
        XCTAssertEqual(layout.items(at: .collapsed), [.metric(.cpu), .battery])
    }

    // MARK: - Defaults

    /// The default has to land on the HUD that shipped before this feature —
    /// CPU and memory on the shoulders, one each side — or turning the feature
    /// on would silently rearrange somebody's notch.
    func testTheDefaultParkedHUDIsTheOneThatShippedBefore() {
        let layout = HUDItemLayout.default
        XCTAssertEqual(layout.items(on: .left, at: .collapsed), [.metric(.cpu)])
        XCTAssertEqual(layout.items(on: .right, at: .collapsed), [.metric(.memory)])
    }

    /// Every stage has to be worth reaching, or the gesture that reaches it
    /// looks broken.
    func testEveryStageOfTheDefaultShowsSomethingNew() {
        let layout = HUDItemLayout.default
        let parked = layout.items(at: .collapsed)
        let peeking = layout.items(at: .peek)
        let open = layout.items(at: .expanded)

        XCTAssertGreaterThan(peeking.count, parked.count, "hovering would add nothing")
        XCTAssertGreaterThan(open.count, peeking.count, "clicking would add nothing")
    }

    func testHasItemsReportsAnEmptyStage() {
        XCTAssertTrue(HUDItemLayout.default.hasItems(at: .collapsed))
        XCTAssertFalse(HUDItemLayout(placements: [:]).hasItems(at: .expanded))
    }

    // MARK: - Storage

    func testALayoutSurvivesARoundTrip() {
        var layout = HUDItemLayout.default
        layout.set(HUDItemPlacement(isEnabled: true, side: .right, stage: .expanded), for: .metric(.cpu))
        layout.set(HUDItemPlacement(isEnabled: false, side: .left, stage: .peek), for: .battery)

        let restored = HUDItemLayout(storageValues: layout.storageValues)
        XCTAssertNotNil(restored)
        // Every item, switched off ones included: all three axes survive.
        for kind in HUDItemKind.allCases {
            XCTAssertEqual(
                restored?.placement(for: kind),
                layout.placement(for: kind),
                "\(kind.rawValue) did not survive"
            )
        }
    }

    /// Nothing stored is a new user, and they get the shipped placement.
    func testNothingStoredIsNotTheSameAsEverythingOff() {
        XCTAssertNil(HUDItemLayout(storageValues: nil))

        // An empty list is a real choice — every switch off — and it has to
        // survive a relaunch rather than repopulating itself.
        let emptied = HUDItemLayout(storageValues: [])
        XCTAssertNotNil(emptied)
        XCTAssertFalse(emptied!.hasItems(at: .expanded))
    }

    /// Switching a readout off must not throw away where the user had put it —
    /// turning it back on should return it to the same side and the same stage.
    func testSwitchingAnItemOffKeepsItsPlacement() {
        var layout = HUDItemLayout()
        layout.set(HUDItemPlacement(isEnabled: false, side: .right, stage: .peek), for: .metric(.cpu))

        let restored = HUDItemLayout(storageValues: layout.storageValues)
        XCTAssertEqual(
            restored?.placement(for: .metric(.cpu)),
            HUDItemPlacement(isEnabled: false, side: .right, stage: .peek)
        )
    }

    func testTheStoredFormIsReadableAndTheFlagIsOptional() {
        var layout = HUDItemLayout()
        layout.set(HUDItemPlacement(isEnabled: true, side: .left, stage: .peek), for: .metric(.disk))
        XCTAssertEqual(layout.storageValues, ["metric.disk:left:peek:on"])

        // The short, hand-written form means "on".
        let terse = HUDItemLayout(storageValues: ["metric.disk:left:peek"])
        XCTAssertEqual(terse?.placement(for: .metric(.disk)).isEnabled, true)
    }

    /// One unreadable line is no reason to throw away the rest of somebody's
    /// configuration.
    func testAMalformedEntryIsSkippedRatherThanFailingTheParse() {
        let restored = HUDItemLayout(storageValues: [
            "metric.cpu:left:collapsed",
            "nonsense",
            "battery:sideways:peek",
            "metric.memory:right:never",
            "battery:right:peek",
        ])
        XCTAssertEqual(restored?.items(on: .left, at: .collapsed), [.metric(.cpu)])
        XCTAssertEqual(restored?.items(on: .right, at: .peek), [.battery])
        // The two broken lines took nothing else with them, and the metric
        // whose stage was unreadable stayed off rather than guessing.
        XCTAssertFalse(restored?.placement(for: .metric(.memory)).isEnabled ?? true)
    }

    /// An item a later release adds starts off for someone with a stored
    /// layout: the HUD draws over the menu bar, and nothing appears there
    /// without being asked for.
    func testAnItemMissingFromStorageIsOffRatherThanDefaulted() {
        let restored = HUDItemLayout(storageValues: ["metric.cpu:left:collapsed"])
        XCTAssertFalse(restored?.placement(for: .metric(.memory)).isEnabled ?? true)
    }

    // MARK: - Item identity

    func testMetricItemsRoundTripThroughTheirIdentifier() {
        for metric in MetricIdentifier.allCases {
            let kind = HUDItemKind.metric(metric)
            XCTAssertEqual(kind.metric, metric)
            XCTAssertEqual(kind.displayName, metric.displayName)
            XCTAssertTrue(kind.requiresMonitoring)
        }
    }

    func testNonMetricItemsCarryNoMetricAndNeedNoSampler() {
        for kind in [HUDItemKind.battery, .calendarWeek, .keepAwake, .fanProfile] {
            XCTAssertNil(kind.metric)
            XCTAssertFalse(kind.requiresMonitoring)
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
    }

    func testEveryItemHasAnOpinionInTheDefaultLayout() {
        for kind in HUDItemKind.allCases {
            XCTAssertNotNil(
                HUDItemLayout.default.placements[kind],
                "\(kind.rawValue) has no default placement"
            )
        }
    }

    // MARK: - The shoulder budget

    /// A shoulder holds about two readouts. A third is drawn and then clipped,
    /// which reads as a bug rather than as a budget — so the shipped placement
    /// must not put the user in that state before they have touched anything.
    func testTheDefaultNeverOverfillsAShoulder() {
        for stage in [HUDPresentation.collapsed, .peek] {
            for side in HUDItemSide.allCases {
                XCTAssertLessThanOrEqual(
                    HUDItemLayout.default.items(on: side, at: stage).count,
                    2,
                    "\(side.rawValue) shoulder is overfilled at \(stage.rawValue)"
                )
            }
        }
    }

    // MARK: - Card height

    /// The card used to ask for a fixed height, which left a third of the panel
    /// as empty black once the contents became configurable.
    func testTheCardGrowsWithTheNumberOfRows() {
        var small = HUDItemLayout()
        small.set(HUDItemPlacement(isEnabled: true, side: .left, stage: .expanded), for: .metric(.cpu))

        var large = small
        for kind in HUDItemKind.allCases {
            large.set(HUDItemPlacement(isEnabled: true, side: .left, stage: .expanded), for: kind)
        }

        XCTAssertLessThan(
            HUDDockLayout.expandedContentHeight(for: small, dock: .notch),
            HUDDockLayout.expandedContentHeight(for: large, dock: .notch)
        )
    }

    /// The notch card is two columns, so a second column costs nothing in
    /// height. An edge card is one, so it costs a row.
    func testTheNotchCardIsSetByItsTallerColumnAndTheEdgeCardBySum() {
        var layout = HUDItemLayout()
        layout.set(HUDItemPlacement(isEnabled: true, side: .left, stage: .expanded), for: .metric(.cpu))
        let oneSided = HUDDockLayout.expandedContentHeight(for: layout, dock: .notch)

        layout.set(HUDItemPlacement(isEnabled: true, side: .right, stage: .expanded), for: .battery)
        XCTAssertEqual(
            HUDDockLayout.expandedContentHeight(for: layout, dock: .notch),
            oneSided,
            "a second column should not make the notch card taller"
        )
        XCTAssertGreaterThan(
            HUDDockLayout.expandedContentHeight(for: layout, dock: .right(.center)),
            HUDDockLayout.expandedContentHeight(for: layout, dock: .notch),
            "the edge card stacks both sides and must be taller"
        )
    }

    /// An empty card still has to be tall enough to draw its actions in.
    func testAnEmptyCardStillHasRoomForItsButtons() {
        XCTAssertGreaterThanOrEqual(
            HUDDockLayout.expandedContentHeight(for: HUDItemLayout(), dock: .notch),
            HUDDockLayout.expandedChromeHeight
        )
    }
}
