import XCTest
@testable import SymOperateCore

final class InputServiceTests: XCTestCase {
    // A point deep off-screen so posted synthetic mouse events cannot land on
    // (and disturb) any real window during the test run.
    private let offscreen = PointValue(x: -10000, y: -10000)

    // MARK: - click

    func testClickLeftButtonSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.click(at: offscreen, button: "left"))
    }

    func testClickRightButtonSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.click(at: offscreen, button: "right"))
    }

    func testClickCaseInsensitiveButton() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.click(at: offscreen, button: "LEFT"))
    }

    func testClickDoubleClickSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.click(at: offscreen, button: "left", doubleClick: true))
    }

    func testClickInvalidButtonThrows() {
        let service = InputService()
        XCTAssertThrowsError(try service.click(at: offscreen, button: "middle")) { error in
            guard let automationError = error as? AutomationError, case .invalidArgument = automationError else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    // MARK: - drag

    func testDragSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.drag(from: offscreen, to: PointValue(x: -9000, y: -9000), steps: 3))
    }

    func testDragClampsStepsBelowMinimum() throws {
        // steps < 2 is clamped to 2 internally — must not crash on a degenerate range.
        let service = InputService()
        XCTAssertNoThrow(try service.drag(from: offscreen, to: PointValue(x: -9000, y: -9000), steps: 0))
    }

    // MARK: - scroll

    func testScrollSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.scroll(deltaX: 1, deltaY: 10))
    }

    func testScrollDefaultDeltaXSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.scroll(deltaY: -5))
    }

    // MARK: - typeText

    func testTypeTextSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.typeText("hi"))
    }

    func testTypeTextEmptyStringSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.typeText(""))
    }

    // MARK: - pressKeys

    func testPressKeysEmptyArrayThrows() {
        let service = InputService()
        XCTAssertThrowsError(try service.pressKeys([])) { error in
            guard let automationError = error as? AutomationError, case .invalidArgument = automationError else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func testPressKeysKnownKeyCodeSucceeds() throws {
        let service = InputService()
        XCTAssertNoThrow(try service.pressKeys(["cmd", "a"]))
    }

    func testPressKeysFallsBackToTypeTextForUnknownKey() throws {
        // "hello" has no single-key mapping, so KeyboardShortcut.parse resolves
        // it as fallback text and pressKeys routes it through typeText.
        let service = InputService()
        XCTAssertNoThrow(try service.pressKeys(["hello"]))
    }

    func testPressKeysModifierOnlyThrowsUnresolvable() {
        // A pure modifier list with no terminal key and no fallback text can't
        // be resolved to a key code or typed text.
        let service = InputService()
        XCTAssertThrowsError(try service.pressKeys(["cmd", "ctrl", "alt", "shift"])) { error in
            guard let automationError = error as? AutomationError, case .invalidArgument = automationError else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }
}

final class KeyboardShortcutTests: XCTestCase {
    func testParseAllModifiers() {
        let parsed = KeyboardShortcut.parse(["cmd", "ctrl", "alt", "shift", "a"])
        XCTAssertTrue(parsed.flags.contains(.maskCommand))
        XCTAssertTrue(parsed.flags.contains(.maskControl))
        XCTAssertTrue(parsed.flags.contains(.maskAlternate))
        XCTAssertTrue(parsed.flags.contains(.maskShift))
        XCTAssertEqual(parsed.keyCode, 0)
    }

    func testParseUnknownKeyFallsBackToText() {
        let parsed = KeyboardShortcut.parse(["unknownkey"])
        XCTAssertNil(parsed.keyCode)
        XCTAssertEqual(parsed.fallbackText, "unknownkey")
    }

    func testParseNamedSpecialKeys() {
        for name in ["tab", "space", "return", "enter", "escape", "esc", "delete", "backspace", "up", "down", "left", "right"] {
            let parsed = KeyboardShortcut.parse([name])
            XCTAssertNotNil(parsed.keyCode, "expected a key code mapping for '\(name)'")
        }
    }
}
