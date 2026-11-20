import Foundation
import XCTest
@testable import HereforthCore

final class WorkRequestsTests: XCTestCase {
    func testDurableIntakeRetryAndReviewWithoutAnExternalEffect() throws {
        try withLibrary { directory, store in
            let requestID = UUID().uuidString
            let request = try store.submitWorkRequest(sender: "Ryan", requestID: requestID, category: "data_access",
                                                      body: "Request access to the warehouse.")
            XCTAssertEqual(try store.submitWorkRequest(sender: "Ryan", requestID: requestID.lowercased(),
                                                       category: "data_access", body: "Request access to the warehouse."), request)
            XCTAssertThrowsError(try store.submitWorkRequest(sender: "Ryan", requestID: requestID,
                                                            category: "data_access", body: "Different request"))
            XCTAssertThrowsError(try store.submitWorkRequest(sender: "Ryan", requestID: requestID,
                                                            category: "data_access", body: "Request access to the warehouse.",
                                                            requestsBrief: true))
            XCTAssertThrowsError(try store.submitWorkRequest(sender: "Ryan", requestID: UUID().uuidString,
                                                            category: "vendor", body: "Review this", requestsBrief: true))
            let reopened = try Store(directory: directory)
            XCTAssertEqual(try reopened.workRequests().first?.state, "pending")
            XCTAssertTrue(try reopened.publishedSessions().isEmpty)
            XCTAssertNil(try reopened.workRequestStatus(sender: "Other", requestID: requestID))
            XCTAssertNil(try reopened.readWorkRequestGrant(sender: "Ryan", requestID: requestID))
            XCTAssertFalse(try XCTUnwrap(reopened.workRequests().first).requestsBrief)
            XCTAssertThrowsError(try reopened.previewWorkRequest(id: request, briefID: UUID().uuidString))
            XCTAssertEqual(try reopened.reviewWorkRequest(id: request, approve: true).state, "reviewed")
            XCTAssertEqual(try reopened.workRequestStatus(sender: "Ryan", requestID: requestID)?.state, "reviewed")
            XCTAssertNil(try reopened.readWorkRequestGrant(sender: "Ryan", requestID: requestID))
        }
    }

    func testPairedIdentitySeparatesOwnershipFromDisplayName() throws {
        try withLibrary { _, store in
            let first = "Ryan [hf-pair:" + String(repeating: "a", count: 32) + "]"
            let second = "Ryan [hf-pair:" + String(repeating: "b", count: 32) + "]"
            let requestID = UUID().uuidString
            let id = try store.submitWorkRequest(sender: first, requestID: requestID, category: "it", body: "Review this.")
            XCTAssertEqual(try store.workRequests().first?.sender, "Ryan")
            XCTAssertEqual(try store.workRequestStatus(sender: first, requestID: requestID)?.id, id)
            XCTAssertNil(try store.workRequestStatus(sender: second, requestID: requestID))
            XCTAssertNil(try store.workRequestStatus(sender: "Ryan", requestID: requestID))
            XCTAssertEqual(store.senderLabel("Ryan [hf-pair:literal]"), "Ryan [hf-pair:literal]")
        }
    }

    func testExactRevisionIsPinnedForOneSenderAndRevocable() throws {
        try withLibrary { directory, store in
            let brief = try makeBrief(directory, store)
            let requestID = UUID().uuidString
            let request = try store.submitWorkRequest(sender: "Ryan", requestID: requestID, category: "data_access",
                                                      body: "Read the reviewed brief.", briefID: brief.id)
            let other = try store.submitWorkRequest(sender: "Other", requestID: requestID, category: "data_access",
                                                    body: "Read the reviewed brief.", briefID: brief.id)
            XCTAssertThrowsError(try store.previewWorkRequest(id: request, briefID: UUID().uuidString))
            let stale = try store.previewWorkRequest(id: request, briefID: brief.id)
            XCTAssertEqual(stale.sender, "Ryan")
            XCTAssertEqual(stale.title, brief.title)
            try store.updateBrief(brief.id, markdown: "Reviewed and redacted.")
            XCTAssertThrowsError(try store.reviewWorkRequest(id: request, approve: true, briefID: stale.briefID, digest: stale.digest))
            XCTAssertEqual(try store.workRequestStatus(sender: "Ryan", requestID: requestID)?.state, "pending")
            let current = try store.previewWorkRequest(id: request, briefID: brief.id)
            let fulfilled = try store.reviewWorkRequest(id: request, approve: true, briefID: current.briefID, digest: current.digest)
            XCTAssertEqual(fulfilled.state, "fulfilled")
            XCTAssertNil(try store.readWorkRequestGrant(sender: "Other", requestID: requestID))
            XCTAssertEqual(try store.workRequestStatus(sender: "Other", requestID: requestID)?.id, other)
            XCTAssertEqual(try store.workRequestStatus(sender: "Other", requestID: requestID)?.state, "pending")
            try store.updateBrief(brief.id, markdown: "Later private revision.")
            let read = try XCTUnwrap(Store(directory: directory).readWorkRequestGrant(sender: "Ryan", requestID: requestID))
            XCTAssertEqual(read.markdown, "Reviewed and redacted.")
            XCTAssertEqual(read.digest, current.digest)
            XCTAssertEqual(read.briefID, brief.id)
            XCTAssertTrue(fulfilled.receipt.contains(read.expiresAt))
            XCTAssertEqual(try store.reviewWorkRequest(id: request, approve: true, briefID: current.briefID,
                                                       digest: current.digest).receipt, fulfilled.receipt)
            try store.revokeWorkRequest(id: request)
            try store.revokeWorkRequest(id: request)
            XCTAssertNil(try store.readWorkRequestGrant(sender: "Ryan", requestID: requestID))
            XCTAssertEqual(try store.workRequestStatus(sender: "Ryan", requestID: requestID)?.state, "revoked")
            XCTAssertThrowsError(try store.reviewWorkRequest(id: request, approve: true, briefID: current.briefID, digest: current.digest))
        }
    }

    func testOwnerSelectionAndExpiryWithoutGrantRenewal() throws {
        try withLibrary { directory, store in
            let brief = try makeBrief(directory, store)
            let requestID = UUID().uuidString
            let request = try store.submitWorkRequest(sender: "Ryan", requestID: requestID, category: "data_access",
                                                      body: "Read the planning brief by title.", requestsBrief: true)
            XCTAssertNil(try store.workRequests().first?.briefID)
            XCTAssertThrowsError(try store.reviewWorkRequest(id: request, approve: true))
            let preview = try store.previewWorkRequest(id: request, briefID: brief.id)
            XCTAssertEqual(try store.reviewWorkRequest(id: request, approve: true, briefID: preview.briefID,
                                                       digest: preview.digest).briefID, brief.id)
            try store.db.execute("UPDATE work_requests SET grant_expires = unixepoch() - 1 WHERE id = ?", [request])
            XCTAssertNil(try store.readWorkRequestGrant(sender: "Ryan", requestID: requestID))
            XCTAssertEqual(try store.workRequestStatus(sender: "Ryan", requestID: requestID)?.state, "expired")
            XCTAssertEqual(try store.workRequests().first?.state, "expired")
            XCTAssertEqual(try store.reviewWorkRequest(id: request, approve: true, briefID: preview.briefID,
                                                       digest: preview.digest).state, "expired")
            XCTAssertNil(try store.readWorkRequestGrant(sender: "Ryan", requestID: requestID))
        }
    }

    private func makeBrief(_ directory: URL, _ store: Store) throws -> Brief {
        let transcript = directory.appendingPathComponent("planning.txt")
        try "Private source text.".write(to: transcript, atomically: true, encoding: .utf8)
        _ = try store.importFile(transcript)
        let hit = try XCTUnwrap(store.search("source").first)
        return try store.draft(recipient: "Ryan", title: "Planning", decision: "Friday",
                               background: "Planning discussion", nextStep: "Confirm", citations: [hit.citation])
    }

    private func withLibrary(_ body: (URL, Store) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, Store(directory: directory))
    }
}
