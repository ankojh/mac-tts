import XCTest
import AppKit
@testable import Hush

final class SourceHighlightTests: XCTestCase {
    func testFormattedAnnotationsPreserveSourceOffsets() {
        let text = NSMutableAttributedString(string: "🎧 Claim12 and result3.")
        text.addAttribute(.superscript, value: 1, range: (text.string as NSString).range(of: "12"))
        text.addAttribute(.superscript, value: -1, range: (text.string as NSString).range(of: "3"))
        let masked = TextCapture.maskAnnotations(text)
        XCTAssertEqual(masked, "🎧 Claim   and result .")
        XCTAssertEqual(masked.utf16.count, text.length)
        XCTAssertEqual((masked as NSString).range(of: "result"), (text.string as NSString).range(of: "result"))
    }

    func testMapsSelectionAcrossFormattingLeaves() {
        let spans = SourceTextMapper.map(selection: "Read this bold phrase. Then continue.",
                                         leaves: ["Ignore me. ", "Read this ", "bold", " phrase.", "Then continue.", "Extra"])
        XCTAssertEqual(spans.map(\.leaf), [1, 2, 3, 4])
        XCTAssertEqual(spans[1].sourceStart, 10)
        XCTAssertEqual(spans[3].sourceStart, 23)
    }

    func testPartialSelectionAndUnicodeOffsets() {
        let spans = SourceTextMapper.map(selection: "🎧 café", leaves: ["Prefix 🎧 café suffix"])
        XCTAssertEqual(spans, [.init(sourceStart: 0, sourceLength: 7, leaf: 0, leafOffset: 7, leafLength: 7)])
    }

    func testWhitespaceDifferencesDoNotShiftFollowingWords() {
        let spans = SourceTextMapper.map(selection: "first\n\nsecond", leaves: ["first second"])
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[1].sourceStart, 7)
        XCTAssertEqual(spans[1].leafOffset, 6)
    }

    func testRejectsAmbiguousTextWithoutAnAnchor() {
        XCTAssertTrue(SourceTextMapper.map(selection: "Repeated", leaves: ["Repeated", "Repeated"]).isEmpty)
        XCTAssertEqual(SourceTextMapper.map(selection: "Repeated", leaves: ["Repeated", "Repeated"], preferredLeaf: 1).first?.leaf, 1)
        XCTAssertEqual(SourceTextMapper.map(selection: "yes", leaves: ["yes yes"], preferredLeaf: 0, preferredOffset: 4).first?.leafOffset, 4)
    }

    func testDoesNotGuessWhenContentChanged() {
        XCTAssertTrue(SourceTextMapper.map(selection: "Old content", leaves: ["New content"]).isEmpty)
    }

    func testMergesWordsButKeepsSeparateLines() {
        let rectangles = HighlightGeometry.mergeLines([
            CGRect(x: 10, y: 10, width: 30, height: 18),
            CGRect(x: 45, y: 10, width: 50, height: 18),
            CGRect(x: 10, y: 35, width: 70, height: 18)
        ])
        XCTAssertEqual(rectangles.count, 2)
        XCTAssertEqual(rectangles[0], CGRect(x: 10, y: 10, width: 85, height: 18))
    }

    func testCoordinatesOnDisplaysAboveAndBesidePrimary() {
        XCTAssertEqual(HighlightGeometry.appKitRect(CGRect(x: -600, y: -400, width: 100, height: 20), primaryTop: 900),
                       CGRect(x: -600, y: 1280, width: 100, height: 20))
    }
}
