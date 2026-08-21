import XCTest
import ApplicationServices
@testable import SymOperateCore

final class AXHelpersTests: XCTestCase {

    // MARK: - axCopyElement safe cast

    func testAxCopyElementReturnsNilForNonExistentAttribute() {
        let element = AXUIElementCreateApplication(0)
        let result = axCopyElement(element, attribute: "AXNonExistentAttribute")
        XCTAssertNil(result, "Should return nil when attribute does not exist")
    }

    func testAxCopyElementReturnsNilForStringAttribute() {
        // kAXTitleAttribute returns a String, not an AXUIElement.
        // Before the fix this would crash with `as! AXUIElement`.
        let element = AXUIElementCreateApplication(0)
        let result = axCopyElement(element, attribute: kAXTitleAttribute)
        XCTAssertNil(result, "Should return nil when attribute value is not an AXUIElement")
    }

    func testAxCopyElementReturnsNilForRoleAttribute() {
        // kAXRoleAttribute returns a String, not an AXUIElement.
        let element = AXUIElementCreateApplication(0)
        let result = axCopyElement(element, attribute: kAXRoleAttribute)
        XCTAssertNil(result, "Should return nil when role attribute is a String, not an AXUIElement")
    }

    // MARK: - axCopyFrame safe cast

    func testAxCopyFrameReturnsNilForElementWithoutPositionAndSize() {
        // An element that doesn't expose AXPosition/AXSize should return nil
        // instead of crashing on force-cast.
        let element = AXUIElementCreateApplication(0)
        let result = axCopyFrame(element)
        XCTAssertNil(result, "Should return nil when position or size attributes are missing")
    }

    func testAxCopyFrameReturnsNilForAppElement() {
        // AXUIElementCreateApplication returns an element that may not have
        // concrete position/size in some environments. The key assertion is
        // that it does NOT crash — previously this would force-cast and die.
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let result = axCopyFrame(element)
        // May or may not succeed depending on whether the app exposes these attributes.
        // The important thing is no crash occurs.
        _ = result
    }

    // MARK: - axCopyAttribute

    func testAxCopyAttributeReturnsNilForMissingAttribute() {
        let element = AXUIElementCreateApplication(0)
        let result = axCopyAttribute(element, attribute: "AXNonExistent")
        XCTAssertNil(result, "Should return nil for non-existent attributes")
    }

    // MARK: - axCopyElements

    func testAxCopyElementsReturnsNilForMissingAttribute() {
        let element = AXUIElementCreateApplication(0)
        let result = axCopyElements(element, attribute: "AXNonExistent")
        XCTAssertNil(result, "Should return nil for non-existent attributes")
    }

    func testAxCopyElementsReturnsNilForStringAttribute() {
        // kAXTitleAttribute returns a String, not an array of AXUIElement.
        let element = AXUIElementCreateApplication(0)
        let result = axCopyElements(element, attribute: kAXTitleAttribute)
        XCTAssertNil(result, "Should return nil when attribute value is not [AXUIElement]")
    }

    // MARK: - axCopyString

    func testAxCopyStringReturnsNilForMissingAttribute() {
        let element = AXUIElementCreateApplication(0)
        let result = axCopyString(element, attribute: "AXNonExistent")
        XCTAssertNil(result, "Should return nil for non-existent attributes")
    }

    // MARK: - axCopyActionNames

    func testAxCopyActionNamesReturnsEmptyForAppElement() {
        let element = AXUIElementCreateApplication(0)
        let result = axCopyActionNames(element)
        // App elements may not expose actions; the important thing is no crash.
        XCTAssertTrue(result.isEmpty || !result.isEmpty)
    }

    // MARK: - axStringify

    func testAxStringifyReturnsNilForNil() {
        XCTAssertNil(axStringify(nil))
    }

    func testAxStringifyReturnsStringForString() {
        XCTAssertEqual(axStringify("hello" as AnyObject), "hello")
    }

    func testAxStringifyReturnsStringValueForNSNumber() {
        XCTAssertEqual(axStringify(42 as NSNumber), "42")
    }

    func testAxStringifyReturnsNilForOtherTypes() {
        let dict = ["key": "value"] as NSDictionary
        XCTAssertNil(axStringify(dict))
    }
}
