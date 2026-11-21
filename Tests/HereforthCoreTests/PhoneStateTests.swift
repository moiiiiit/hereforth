import Darwin
import Foundation
import XCTest
@testable import HereforthCore

final class PhoneStateTests: XCTestCase {
    func testTaskIsDurableOwnerIntentAndRetriesRequireSameContent() throws {
        try useStore { store, root in
            let id = UUID().uuidString
            let prompt = "Prepare a summary after local review."
            let task = try store.queueOwnerTask(requestID: id, client: "codex", kind: "computer", prompt: prompt)
            XCTAssertEqual(task.state, "pending_review")
            XCTAssertEqual(try store.queueOwnerTask(requestID: id.lowercased(), client: "codex", kind: "computer", prompt: prompt).id, id)
            XCTAssertThrowsError(try store.queueOwnerTask(requestID: id, client: "codex", kind: "text", prompt: prompt))
            XCTAssertThrowsError(try store.queueOwnerTask(requestID: UUID().uuidString, client: "/bin/sh", kind: "text", prompt: prompt))

            let anotherProcessView = try Store(directory: root)
            XCTAssertEqual(try anotherProcessView.ownerTask(id: id).prompt, prompt)
            XCTAssertEqual(try anotherProcessView.reviewOwnerTask(id: id, approve: true).state, "approved")
            XCTAssertEqual(try store.ownerTasks().first?.state, "approved")
            XCTAssertEqual(try store.reviewOwnerTask(id: id, approve: true).state, "approved")
            XCTAssertThrowsError(try store.reviewOwnerTask(id: id, approve: false))
        }
    }

    func testHandoffRequiresUnchangedPreviewAndStablePeerThenPinsTheRetry() throws {
        try useStore { store, root in
            let fixture = root.appendingPathComponent("work.txt")
            try "Synthetic decision.".write(to: fixture, atomically: true, encoding: .utf8)
            _ = try store.importFile(fixture)
            let citation = try XCTUnwrap(store.search("decision").first?.citation)
            let brief = try store.draft(recipient: "Ryan", title: "Review update", decision: "Proceed",
                                        background: "A synthetic example", nextStep: "Check the result", citations: [citation])
            let session = UUID().uuidString
            let request = UUID().uuidString
            let original = try store.preparePhoneHandoff(briefID: brief.id, peer: "Ryan", sessionID: session,
                                                         sessionLabel: "Work", destinationKey: "credential-1", requestID: request)
            XCTAssertThrowsError(try store.startPhoneHandoff(id: request, digest: "modified", destinationKey: "credential-1"))
            XCTAssertThrowsError(try store.startPhoneHandoff(id: request, digest: original.digest, destinationKey: "credential-2"))
            try store.updateBrief(brief.id, markdown: "Edited before approval.")
            XCTAssertThrowsError(try store.startPhoneHandoff(id: request, digest: original.digest, destinationKey: "credential-1"))
            XCTAssertEqual(try store.phoneHandoff(request).state, "prepared")

            let fresh = try store.preparePhoneHandoff(briefID: brief.id, peer: "Ryan", sessionID: session,
                                                      sessionLabel: "Work", destinationKey: "credential-1", requestID: UUID().uuidString)
            let sending = try store.startPhoneHandoff(id: fresh.id, digest: fresh.digest, destinationKey: "credential-1")
            XCTAssertEqual(sending.state, "sending")
            try store.updateBrief(brief.id, markdown: "Edited after authorized send started.")
            let retry = try Store(directory: root).startPhoneHandoff(id: fresh.id, digest: fresh.digest, destinationKey: "credential-1")
            XCTAssertEqual(retry.markdown, sending.markdown)
            let receipt = UUID().uuidString
            XCTAssertEqual(try store.recordPhoneHandoffDelivery(id: fresh.id, receipt: receipt).state, "sent")
            XCTAssertEqual(try store.recordPhoneHandoffDelivery(id: fresh.id, receipt: receipt).receipt, receipt)
            XCTAssertThrowsError(try store.recordPhoneHandoffDelivery(id: fresh.id, receipt: UUID().uuidString))
        }
    }

    func testPublicRoutingDirectoryOmitsPrivateActivity() throws {
        try useStore { store, _ in
            let sessionID = UUID().uuidString.lowercased()
            try store.publishSession(id: sessionID, label: "Public routing label", pid: getpid(), client: "synthetic-client")
            let assembled = try XCTUnwrap(store.assistantSessions().first)
            XCTAssertFalse(assembled.publishedAt.isEmpty)
            XCTAssertEqual(assembled.state, "published")
            XCTAssertEqual(assembled.client, "synthetic-client")
            XCTAssertEqual(assembled.phase, "")
            try store.updateSessionActivity(sessionID: sessionID, summary: "Private progress summary", phase: "running")
            let activity = try XCTUnwrap(store.assistantSessions().first)
            XCTAssertEqual(activity.summary, "Private progress summary")
            XCTAssertEqual(activity.phase, "running")
            XCTAssertFalse(activity.activityAt.isEmpty)
            let shared = try JSONEncoder().encode(store.publishedSessions())
            XCTAssertFalse(String(decoding: shared, as: UTF8.self).contains("Private progress"))
            try store.closeSession(id: sessionID)
            XCTAssertTrue(try store.assistantSessions().isEmpty)
            XCTAssertThrowsError(try store.updateSessionActivity(sessionID: sessionID, summary: "Too late", phase: "running"))
        }
    }

    private func useStore(_ body: (Store, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(Store(directory: root), root)
    }
}
