import AppKit
import SwiftUI
import XCTest
@testable import Hush

final class LayoutTests: XCTestCase {
    @MainActor func testPlayerReportsItsFullHeight() {
        _ = NSApplication.shared
        let model = ReaderModel()
        defer { model.shutdown() }
        model.hasAccessibility = false
        let view = PlayerHostingView(rootView: PlayerView(model: model, hide: {}, resize: { _ in }))
        view.sizingOptions = [.intrinsicContentSize]
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 420)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 440, "The welcome text and permission card must not be clipped into the old 420-point window.")
        XCTAssertEqual(view.fittingSize.width, 390, accuracy: 1)
    }
}
