import Foundation
import XCTest
@testable import HereforthCore

final class KeepAwakeStatusTests: XCTestCase {
    func testStatusRequiresCurrentProcessAndUnexpiredAssertion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try Store(directory: directory)
        let assistant = try Store(directory: directory)
        let opening = try assistant.keepAwakeStatus()
        XCTAssertFalse(opening.appRunning)
        XCTAssertFalse(opening.active)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let until = now.addingTimeInterval(60)
        try app.setKeepAwakeStatus(mode: "display", endsAt: until, intervalSeconds: 30, pointerState: "enabled")
        let active = try assistant.keepAwakeStatus(now: now)
        XCTAssertTrue(active.appRunning)
        XCTAssertTrue(active.active)
        XCTAssertEqual(active.mode, "display")
        XCTAssertEqual(active.endsAt, until)
        XCTAssertEqual(active.intervalSeconds, 30)
        XCTAssertEqual(active.pointerState, "enabled")

        let expired = try assistant.keepAwakeStatus(now: until)
        XCTAssertTrue(expired.appRunning)
        XCTAssertFalse(expired.active)
        XCTAssertNil(expired.mode)
        XCTAssertNil(expired.endsAt)
        XCTAssertEqual(expired.pointerState, "off")

        try app.db.execute("UPDATE keep_awake_status SET process_start = 'different process'")
        let restarted = try assistant.keepAwakeStatus(now: now)
        XCTAssertFalse(restarted.appRunning)
        XCTAssertFalse(restarted.active)
        XCTAssertEqual(restarted.intervalSeconds, 30)
        XCTAssertEqual(restarted.pointerState, "off")

        try app.setKeepAwakeStatus(mode: nil, endsAt: nil, intervalSeconds: 60, pointerState: "permissionRequired")
        let idle = try assistant.keepAwakeStatus(now: now)
        XCTAssertTrue(idle.appRunning)
        XCTAssertFalse(idle.active)
        XCTAssertEqual(idle.pointerState, "permissionRequired")
    }
}
