import AppKit
import ApplicationServices
import Foundation

public struct InputService: InputServiceProtocol {
    public init() {}

    public func click(at point: PointValue, button: String = "left", doubleClick: Bool = false) throws {
        try click(at: point, button: button, doubleClick: doubleClick, deliveryMode: .automatic, targetProcessID: nil)
    }

    public func click(at point: PointValue, button: String, doubleClick: Bool, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        let mouseButton = try parseMouseButton(button)
        let downType: CGEventType = (mouseButton == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (mouseButton == .left) ? .leftMouseUp : .rightMouseUp

        try postMouseEvent(type: .mouseMoved, point: point, button: mouseButton, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        for index in 0..<(doubleClick ? 2 : 1) {
            try postMouseEvent(type: downType, point: point, button: mouseButton, clickState: Int64(index + 1), deliveryMode: deliveryMode, targetProcessID: targetProcessID)
            try postMouseEvent(type: upType, point: point, button: mouseButton, clickState: Int64(index + 1), deliveryMode: deliveryMode, targetProcessID: targetProcessID)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public func drag(from start: PointValue, to end: PointValue, steps: Int = 24) throws {
        try drag(from: start, to: end, steps: steps, deliveryMode: .automatic, targetProcessID: nil)
    }

    public func drag(from start: PointValue, to end: PointValue, steps: Int, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        try postMouseEvent(type: .leftMouseDown, point: start, button: .left, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        let stepCount = max(steps, 2)
        for step in 1...stepCount {
            let t = Double(step) / Double(stepCount)
            let x = start.x + ((end.x - start.x) * t)
            let y = start.y + ((end.y - start.y) * t)
            try postMouseEvent(type: .leftMouseDragged, point: PointValue(x: x, y: y), button: .left, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
            Thread.sleep(forTimeInterval: 0.01)
        }
        try postMouseEvent(type: .leftMouseUp, point: end, button: .left, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
    }

    public func scroll(deltaX: Double = 0, deltaY: Double) throws {
        try scroll(deltaX: deltaX, deltaY: deltaY, deliveryMode: .automatic, targetProcessID: nil)
    }

    public func scroll(deltaX: Double, deltaY: Double, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        guard deliveryMode != .background else {
            throw AutomationError.unsupported("Background delivery for scroll is unsupported without a verified target process.")
        }
        // MCP clients can supply arbitrary JSON numbers. Validate both deltas
        // before converting so malformed input cannot trap the server process.
        let wheel1 = try validatedScrollDelta(deltaY, name: "delta_y")
        let wheel2 = try validatedScrollDelta(deltaX, name: "delta_x")

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else {
            throw AutomationError.operationFailed("Failed to create a scroll event.")
        }
        try post(event, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
    }

    private func validatedScrollDelta(_ value: Double, name: String) throws -> Int32 {
        guard value.isFinite else {
            throw AutomationError.invalidArgument("Scroll \(name) must be finite.")
        }
        guard value >= Double(Int32.min), value <= Double(Int32.max) else {
            throw AutomationError.invalidArgument("Scroll \(name) must be within the Int32 range.")
        }

        // Preserve the old truncation-toward-zero behavior for fractional
        // in-range values while using a failable, non-trapping conversion.
        guard let converted = Int32(exactly: value.rounded(.towardZero)) else {
            throw AutomationError.invalidArgument("Scroll \(name) must be within the Int32 range.")
        }
        return converted
    }

    public func typeText(_ text: String) throws {
        try typeText(text, deliveryMode: .automatic, targetProcessID: nil)
    }

    public func typeText(_ text: String, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        if deliveryMode == .background && (targetProcessID == nil || targetProcessID! <= 0) {
            throw AutomationError.unsupported("Background delivery for type_text requires a verified target process.")
        }
        for scalar in text.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw AutomationError.operationFailed("Failed to create keyboard events.")
            }

            var utf16 = Array(String(scalar).utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            try postKeyboardEvent(down, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
            try postKeyboardEvent(up, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        }
    }

    public func pressKeys(_ keys: [String]) throws {
        try pressKeys(keys, deliveryMode: .automatic, targetProcessID: nil)
    }

    public func pressKeys(_ keys: [String], deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        if deliveryMode == .background && (targetProcessID == nil || targetProcessID! <= 0) {
            throw AutomationError.unsupported("Background delivery for press_keys requires a verified target process.")
        }
        guard !keys.isEmpty else {
            throw AutomationError.invalidArgument("press_keys requires at least one key.")
        }

        let parsed = KeyboardShortcut.parse(keys)
        if let keyCode = parsed.keyCode {
            try postKeyCode(keyCode, flags: parsed.flags, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        } else if let text = parsed.fallbackText {
            try typeText(text, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        } else {
            throw AutomationError.invalidArgument("Unable to resolve the requested key sequence \(keys).")
        }
    }

    private func postMouseEvent(
        type: CGEventType,
        point: PointValue,
        button: CGMouseButton,
        clickState: Int64 = 1,
        deliveryMode: DeliveryMode,
        targetProcessID: Int32?
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: button
        ) else {
            throw AutomationError.operationFailed("Failed to create a mouse event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        try post(event, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
    }

    private func postKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw AutomationError.operationFailed("Failed to create keycode events.")
        }

        down.flags = flags
        up.flags = flags
        try postKeyboardEvent(down, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
        try postKeyboardEvent(up, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
    }

    private func postKeyboardEvent(_ event: CGEvent, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        try post(event, deliveryMode: deliveryMode, targetProcessID: targetProcessID)
    }

    private func post(_ event: CGEvent, deliveryMode: DeliveryMode, targetProcessID: Int32?) throws {
        switch deliveryMode {
        case .automatic, .foreground:
            event.post(tap: .cghidEventTap)
        case .background:
            guard let targetProcessID, targetProcessID > 0 else {
                throw AutomationError.unsupported("Background delivery requires a verified target process.")
            }
            event.postToPid(pid_t(targetProcessID))
        }
    }

    private func parseMouseButton(_ value: String) throws -> CGMouseButton {
        switch value.lowercased() {
        case "left":
            return .left
        case "right":
            return .right
        default:
            throw AutomationError.invalidArgument("Unsupported mouse button '\(value)'.")
        }
    }
}

struct KeyboardShortcut {
    let flags: CGEventFlags
    let keyCode: CGKeyCode?
    let fallbackText: String?

    static func parse(_ keys: [String]) -> KeyboardShortcut {
        var flags: CGEventFlags = []
        var terminalKey: String?

        for key in keys.map({ $0.lowercased() }) {
            switch key {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "alt", "option":
                flags.insert(.maskAlternate)
            case "shift":
                flags.insert(.maskShift)
            default:
                terminalKey = key
            }
        }

        if let terminalKey, let keyCode = keyCode(for: terminalKey) {
            return KeyboardShortcut(flags: flags, keyCode: keyCode, fallbackText: nil)
        }

        return KeyboardShortcut(flags: flags, keyCode: nil, fallbackText: terminalKey)
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "tab": 48, "space": 49, "return": 36, "enter": 76, "escape": 53, "esc": 53,
            "delete": 51, "backspace": 51, "up": 126, "down": 125, "left": 123, "right": 124
        ]
        return map[key]
    }
}
