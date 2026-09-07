import XCTest
@testable import Hush

final class AccessibilityTests: XCTestCase {
    @MainActor func testPermissionErrorClearsWhenAuthorizationRecovers() {
        let model = ReaderModel()
        defer { model.shutdown() }
        model.error = TextCapture.permissionDeniedMessage
        model.applyAccessibilityStatus(false)
        XCTAssertNotNil(model.error)
        model.applyAccessibilityStatus(true)
        XCTAssertTrue(model.hasAccessibility)
        XCTAssertNil(model.error)
    }

    @MainActor func testPermissionRefreshPreservesUnrelatedErrors() {
        let model = ReaderModel()
        defer { model.shutdown() }
        model.error = "The model could not load."
        model.applyAccessibilityStatus(true)
        XCTAssertEqual(model.error, "The model could not load.")
    }
}
