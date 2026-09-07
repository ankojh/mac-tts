import XCTest
@testable import Hush

final class BackendTests: XCTestCase {
    @MainActor func testPreparationAndRecoveryAcrossWorkerRestart() async throws {
        let backend = Backend()
        defer { backend.reset() }
        let prepared = try await backend.request(["op": "prepare", "text": "🎧 Intro.\n- **Hello** world.", "clean": true], as: PreparedText.self)
        XCTAssertEqual(prepared.segments.map(\.text), ["Intro.", "Hello world."])
        XCTAssertEqual(prepared.segments[0].start, 3) // Emoji occupies two UTF-16 code units.
        backend.reset()
        let status = try await backend.request(["op": "status"], as: EngineStatus.self)
        XCTAssertEqual(status.voices.count, 6)
    }

    @MainActor func testWorkerErrorsAreRecoverable() async throws {
        let backend = Backend()
        defer { backend.reset() }
        do {
            _ = try await backend.request(["op": "unknown"], as: EngineStatus.self)
            XCTFail("An invalid operation must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unknown"))
        }
        let prepared = try await backend.request(["op": "prepare", "text": "Still working."], as: PreparedText.self)
        XCTAssertEqual(prepared.segments.first?.text, "Still working.")
    }
}
