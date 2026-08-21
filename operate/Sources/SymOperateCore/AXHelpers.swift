import ApplicationServices

func axCopyAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let value else { return nil }
    return value
}

func axCopyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    guard let value = axCopyAttribute(element, attribute: attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func axCopyElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    axCopyAttribute(element, attribute: attribute) as? [AXUIElement]
}

func axCopyString(_ element: AXUIElement, attribute: String) -> String? {
    axCopyAttribute(element, attribute: attribute) as? String
}

func axCopyFrame(_ element: AXUIElement) -> RectValue? {
    guard
        let positionValue = axCopyAttribute(element, attribute: kAXPositionAttribute),
        let sizeValue = axCopyAttribute(element, attribute: kAXSizeAttribute)
    else {
        return nil
    }

    // Verify CF types before casting — AX API may return unexpected types
    // when elements become stale mid-flight.
    guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        return nil
    }

    let posAXValue = unsafeDowncast(positionValue, to: AXValue.self)
    let sizeAXValue = unsafeDowncast(sizeValue, to: AXValue.self)

    var point = CGPoint.zero
    var size = CGSize.zero

    guard
        AXValueGetType(posAXValue) == .cgPoint,
        AXValueGetValue(posAXValue, .cgPoint, &point),
        AXValueGetType(sizeAXValue) == .cgSize,
        AXValueGetValue(sizeAXValue, .cgSize, &size)
    else {
        return nil
    }

    return RectValue(x: point.x, y: point.y, width: size.width, height: size.height)
}

func axCopyActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let result = AXUIElementCopyActionNames(element, &names)
    guard result == .success, let array = names as? [String] else { return [] }
    return array
}

func axStringify(_ value: AnyObject?) -> String? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}
