import Foundation
import XCTest
@testable import HereforthCore

final class WritingGuideTests: XCTestCase {
    func testOfflineHumanizerAndMissingResourceFallback() throws {
        let guide = try XCTUnwrap(WritingGuide.humanizer)
        XCTAssertTrue(guide.contains("version: \"\(WritingGuide.humanizerVersion)\""))
        XCTAssertTrue(guide.contains("## Rewrite process"))
        XCTAssertNil(WritingGuide.loadHumanizer(in: []))
        XCTAssertTrue(WritingGuide.baseline.contains("Keep the source's facts"))
    }

    func testVoiceNotesPersistPrivatelyAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let otherDirectory = directory.appendingPathComponent("other")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        XCTAssertEqual(try store.voiceNotes(), "")
        let notes = "Keep the wording direct.\nUse short paragraphs."
        try store.updateVoiceNotes(notes)
        XCTAssertEqual(try Store(directory: directory).voiceNotes(), notes)
        XCTAssertEqual(try Store(directory: otherDirectory).voiceNotes(), "")
        XCTAssertThrowsError(try store.updateVoiceNotes(String(repeating: "é", count: 4_097)))
        XCTAssertThrowsError(try store.updateVoiceNotes("Reject \0 control characters."))
        XCTAssertEqual(try store.voiceNotes(), notes)
        try store.updateVoiceNotes("  \n")
        XCTAssertEqual(try Store(directory: directory).voiceNotes(), "")
    }
}
