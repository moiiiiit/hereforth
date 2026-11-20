import Foundation
import XCTest
@testable import HereforthCore

final class StoreTests: XCTestCase {
    func testReimportAndRemovalKeepOnlyCurrentCitations() throws {
        try withLibrary { directory, store in
            let url = directory.appendingPathComponent("export.json")
            try write([claude(id: "decision", title: "Launch", text: "The launch is Friday.")], to: url)
            XCTAssertEqual(try store.importFile(url), 1)
            let first = try XCTUnwrap(store.search("Friday").first)
            XCTAssertEqual(try store.importFile(url), 1)
            XCTAssertEqual(try store.search("Friday").map(\.citation), [first.citation])

            try write([claude(id: "decision", title: "Revised title", text: "The launch is Friday.")], to: url)
            _ = try store.importFile(url)
            XCTAssertTrue(try store.read(first.citation).contains("Revised title"))

            try write([claude(id: "decision", title: "Revised title", text: "The launch is Monday.")], to: url)
            _ = try store.importFile(url)
            XCTAssertTrue(try store.search("Friday").isEmpty)
            XCTAssertThrowsError(try store.read(first.citation))
            let current = try XCTUnwrap(store.search("Monday").first)
            XCTAssertTrue(try Store(directory: directory).read(current.citation).contains("The launch is Monday."))

            let id = try XCTUnwrap(store.chats().first?.id)
            try store.removeChat(id)
            XCTAssertTrue(try store.search("Monday").isEmpty)
            XCTAssertThrowsError(try store.read(current.citation))
        }
    }

    func testActiveBranchOnlyAndDiverseResults() throws {
        try withLibrary { directory, store in
            let chatGPT: [String: Any] = [
                "id": "chatgpt-1", "title": "Earlier launch discussion", "current_node": "active",
                "mapping": [
                    "root": ["message": NSNull()],
                    "active": ["parent": "root", "message": ["author": ["role": "assistant"],
                               "content": ["content_type": "text", "parts": ["Launch is proposed for Thursday."]]]],
                    "sibling": ["parent": "root", "message": ["author": ["role": "assistant"],
                                "content": ["content_type": "text", "parts": ["Launch is on Saturday."]]]]
                ]
            ]
            let url = directory.appendingPathComponent("export.json")
            try write([chatGPT, claude(id: "decision", title: "Final launch decision", text: "Launch was confirmed on Friday.")], to: url)
            XCTAssertEqual(try store.importFile(url), 2)
            XCTAssertTrue(try store.search("Saturday").isEmpty)
            let hits = try store.search("launch")
            XCTAssertEqual(Set(hits.map(\.provider)), ["Claude", "ChatGPT"])
            XCTAssertEqual(try store.search("confirmed").first?.date, "2026-11-20T17:30:00Z")
        }
    }

    func testMalformedImportLeavesLibraryAndBriefContainsOnlySelectedExcerpts() throws {
        try withLibrary { directory, store in
            let url = directory.appendingPathComponent("export.json")
            let long = "Approved on Friday. " + String(repeating: "🪴", count: 8_500) + "Tail should stay in the library."
            try write([claude(id: "selected", title: "Selected", text: long),
                       claude(id: "private", title: "Private", text: "Unselected context remains private.")], to: url)
            _ = try store.importFile(url)
            let selected = try XCTUnwrap(store.search("Approved").first)
            let pageOne = try store.read(selected.citation)
            XCTAssertTrue(pageOne.hasSuffix("Next offset: 8000"))
            XCTAssertTrue(try store.read(selected.citation, offset: 8_000).hasSuffix("Tail should stay in the library."))

            try write([claude(id: "selected", title: "Replacement", text: "Would overwrite."), ["invalid": true]], to: url)
            XCTAssertThrowsError(try store.importFile(url))
            XCTAssertTrue(try store.read(selected.citation).contains("Approved on Friday."))
            XCTAssertEqual(try store.chats().count, 2)

            let brief = try store.draft(recipient: "Teammate", title: "Launch decision", decision: "Friday",
                                        background: "Earlier proposal was superseded.", nextStep: "Send the invite.",
                                        citations: [selected.citation])
            XCTAssertTrue(brief.markdown.contains("Approved on Friday."))
            XCTAssertFalse(brief.markdown.contains("Tail should stay in the library."))
            XCTAssertFalse(brief.markdown.contains("Unselected context"))
            XCTAssertEqual(try store.briefs().first?.markdown, brief.markdown)
            try store.updateBrief(brief.id, markdown: brief.markdown + "\nReviewed.")
            XCTAssertTrue(try XCTUnwrap(store.briefs().first).markdown.hasSuffix("Reviewed."))
        }
    }

    func testReadIncludesAdjacentDecisionAndCitationWithoutAddingItToBrief() throws {
        try withLibrary { directory, store in
            var thread = claude(id: "decision", title: "Timing", text: "What date works for Juniper?")
            let first = try XCTUnwrap(thread["chat_messages"] as? [[String: Any]])
            thread["chat_messages"] = first + [
                ["uuid": "follow-up", "sender": "human", "created_at": "2026-11-21T17:30:00Z", "text": "Actually Friday instead."]
            ]
            let url = directory.appendingPathComponent("export.json")
            try write([thread, claude(id: "other", title: "Other chat", text: "Juniper was moved to Wednesday.")], to: url)
            _ = try store.importFile(url)
            let topic = try XCTUnwrap(store.search("Juniper").first { $0.title == "Timing" })
            let followup = try XCTUnwrap(store.search("Friday").first)
            let passage = try store.read(topic.citation)
            XCTAssertTrue(passage.contains("Actually Friday instead."))
            XCTAssertTrue(passage.contains(followup.citation))
            XCTAssertTrue(passage.contains("2026-11-21T17:30:00Z"))
            XCTAssertFalse(passage.contains("Wednesday"))
            XCTAssertTrue(try store.read(followup.citation).hasSuffix("Actually Friday instead."))

            let brief = try store.draft(recipient: "Teammate", title: "Juniper", decision: "Decision pending review",
                                        background: "See the source question.", nextStep: "Confirm the date.",
                                        citations: [topic.citation])
            XCTAssertFalse(brief.markdown.contains("Actually Friday instead."))
        }
    }

    func testLibraryDirectoryWithSymlinkedParent() throws {
        try withLibrary { directory, _ in
            let backing = directory.appendingPathComponent("backing")
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: backing, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backing)
            let store = try Store(directory: alias.appendingPathComponent("library"))
            XCTAssertTrue(try store.chats().isEmpty)
            let database = backing.appendingPathComponent("library/hereforth.sqlite")
            let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
            XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
        }
    }

    private func withLibrary(_ body: (URL, Store) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, Store(directory: directory))
    }

    private func write(_ conversations: [[String: Any]], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: conversations).write(to: url, options: .atomic)
    }

    private func claude(id: String, title: String, text: String) -> [String: Any] {
        ["uuid": id, "name": title, "chat_messages": [
            ["uuid": "message", "sender": "assistant", "created_at": "2026-11-20T17:30:00.123Z", "text": text]
        ]]
    }
}
