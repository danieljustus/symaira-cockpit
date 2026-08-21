import XCTest
@testable import SymOperateCore

final class ScreenServiceTests: XCTestCase {
    // MARK: - Screen Recording TCC denial classification

    func testTCCDomainDenialClassifiesAsPermissionDenied() {
        let tccDenial = NSError(
            domain: "com.apple.TCC",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The user denied the screen capture."]
        )
        let classified = ScreenService.classifyCaptureError(tccDenial, context: "Screen capture")
        guard case .permissionDenied = classified else {
            return XCTFail("Expected .permissionDenied, got \(classified)")
        }
        XCTAssertEqual(
            classified.localizedDescription,
            "Screen Recording permission is denied. Enable it in System Settings > Privacy & Security > Screen Recording."
        )
    }

    func testScreenCaptureKit3801ClassifiesAsPermissionDenied() {
        let scDenial = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined the request."]
        )
        let classified = ScreenService.classifyCaptureError(scDenial, context: "Window capture")
        guard case .permissionDenied = classified else {
            return XCTFail("Expected .permissionDenied, got \(classified)")
        }
    }

    func testLocalizedTCCDenialMessageClassifiesAsPermissionDenied() {
        // ScreenCaptureKit surfaces TCC denials with localized messages that vary
        // by system language — e.g. German: "Benutzer:in hat TCCs für die Aufnahme
        // durch Apps, Fenster, Displays abgelehnt" — without a stable error code.
        let localizedDenial = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: -3802,
            userInfo: [
                NSLocalizedDescriptionKey: "Benutzer:in hat TCCs für die Aufnahme durch Apps, Fenster, Displays abgelehnt"
            ]
        )
        let classified = ScreenService.classifyCaptureError(localizedDenial, context: "Screen capture")
        guard case .permissionDenied = classified else {
            return XCTFail("Expected .permissionDenied, got \(classified)")
        }
    }

    func testUnrelatedCaptureErrorRemainsOperationFailed() {
        let generic = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: -9999,
            userInfo: [NSLocalizedDescriptionKey: "Stream error: no frames were received."]
        )
        let classified = ScreenService.classifyCaptureError(generic, context: "Screen capture")
        guard case .operationFailed(let message) = classified else {
            return XCTFail("Expected .operationFailed, got \(classified)")
        }
        XCTAssertTrue(message.contains("Screen capture failed"))
    }

    // MARK: - Typed error pass-through (issue #108)

    func testTypedUnavailableErrorPassesThroughClassifier() {
        // Display-mismatch errors thrown by the capture paths are already
        // classified; the classifier must not re-wrap them as operationFailed.
        let displayMismatch = AutomationError.unavailable("Display 1 not found in ScreenCaptureKit.")
        let classified = ScreenService.classifyCaptureError(displayMismatch, context: "Screen capture")
        guard case .unavailable(let message) = classified else {
            return XCTFail("Expected .unavailable to pass through, got \(classified)")
        }
        XCTAssertEqual(message, "Display 1 not found in ScreenCaptureKit.")
        XCTAssertEqual(classified.code, "element_not_resolvable")
    }

    func testTypedNotFoundErrorPassesThroughClassifier() {
        let windowMissing = AutomationError.notFound("Window 42 not found in ScreenCaptureKit.")
        let classified = ScreenService.classifyCaptureError(windowMissing, context: "Window capture")
        guard case .notFound(let message) = classified else {
            return XCTFail("Expected .notFound to pass through, got \(classified)")
        }
        XCTAssertEqual(message, "Window 42 not found in ScreenCaptureKit.")
    }

    // MARK: - Doctor advice (issue #108)

    func testDoctorAdviceForUnavailableCaptureErrorIsActionable() {
        let advice = DoctorAdvice.screenshotProbeRecommendation(
            for: .unavailable("Display 1 not found in ScreenCaptureKit.")
        )
        XCTAssertTrue(advice.contains("ScreenCaptureKit"), advice)
        XCTAssertTrue(advice.contains("display"), advice)
        XCTAssertTrue(advice.contains("Screen Recording"), advice)
    }

    func testDoctorAdviceForOtherErrorsReturnsLocalizedMessage() {
        let denied = AutomationError.permissionDenied("Screen Recording permission is denied. Enable it.")
        XCTAssertEqual(
            DoctorAdvice.screenshotProbeRecommendation(for: denied),
            "Screen Recording permission is denied. Enable it."
        )
        let failed = AutomationError.operationFailed("Screen capture failed: stream error")
        XCTAssertEqual(
            DoctorAdvice.screenshotProbeRecommendation(for: failed),
            "Screen capture failed: stream error"
        )
    }
}
