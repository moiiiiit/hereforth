import Darwin
import Foundation
import XCTest
@testable import HereforthCore

final class SessionContextTests: XCTestCase {
    func testReviewAndDeliveryAreLimitedToTheAddressedSession() throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        try store.publishSession(id: first, label: "Roadmap", pid: getpid())
        try store.publishSession(id: second, label: "Incident", pid: getpid())
        XCTAssertEqual(Set(try store.publishedSessions().map(\.id)), [first, second])

        let approved = try store.offerContext(sender: "Sender A", sessionID: first, body: "Approved text", requestID: "one")
        let declined = try store.offerContext(sender: "Sender A", sessionID: first, body: "Declined text", requestID: "two")
        let pending = try store.offerContext(sender: "Sender B", sessionID: second, body: "Pending text", requestID: "one")
        XCTAssertEqual(try store.offerStatus(sender: "Sender A", requestID: "one"), "pending")
        XCTAssertNil(try store.offerStatus(sender: "Sender B", requestID: "two"))
        XCTAssertTrue(try store.takeContext(sessionID: first).isEmpty)

        try store.reviewContext(id: approved, approve: true)
        try store.reviewContext(id: declined, approve: false)
        XCTAssertThrowsError(try store.reviewContext(id: declined, approve: true))
        XCTAssertTrue(try store.takeContext(sessionID: second).isEmpty)
        let delivered = try store.takeContext(sessionID: first)
        XCTAssertEqual(delivered.map(\.id), [approved])
        XCTAssertEqual(delivered.first?.body, "Approved text")
        XCTAssertEqual(delivered.first?.sessionLabel, "Roadmap")
        XCTAssertEqual(try store.offerStatus(sender: "Sender A", requestID: "one"), "delivered")
        XCTAssertEqual(try store.offerStatus(sender: "Sender A", requestID: "two"), "declined")
        XCTAssertTrue(try store.takeContext(sessionID: first).isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try store.contextInbox().map { ($0.id, $0.state) }),
                       [approved: "consumed", declined: "declined", pending: "pending"])
    }

    func testRequestReplayValidationAndClosedSessions() throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let session = UUID().uuidString
        try store.publishSession(id: session, label: "Planning", pid: getpid())
        XCTAssertThrowsError(try store.offerContext(sender: "Peer", sessionID: session, body: "\u{0}text", requestID: "invalid"))
        XCTAssertThrowsError(try store.offerContext(sender: "Peer", sessionID: session, body: String(repeating: "🍎", count: 2_049), requestID: "large"))
        XCTAssertThrowsError(try store.offerContext(sender: "Peer", sessionID: UUID().uuidString, body: "Text", requestID: "missing"))

        let offer = try store.offerContext(sender: "Peer", sessionID: session, body: "First\nsecond", requestID: "same")
        XCTAssertEqual(try store.offerContext(sender: "Peer", sessionID: session, body: "First\nsecond", requestID: "same"), offer)
        XCTAssertThrowsError(try store.offerContext(sender: "Peer", sessionID: session, body: "Changed", requestID: "same"))
        XCTAssertEqual(try store.contextInbox().map(\.id), [offer])
        try store.reviewContext(id: offer, approve: true)
        try store.closeSession(id: session)
        XCTAssertTrue(try store.publishedSessions().isEmpty)
        XCTAssertEqual(try store.contextInbox().first?.state, "stale")
        XCTAssertEqual(try store.offerStatus(sender: "Peer", requestID: "same"), "expired")
        XCTAssertTrue(try store.takeContext(sessionID: session).isEmpty)
        XCTAssertThrowsError(try store.publishSession(id: session, label: "Reopened", pid: getpid()))
        XCTAssertThrowsError(try store.offerContext(sender: "Peer", sessionID: session, body: "Text", requestID: "new"))
    }

    func testExpiredOfferAndDeadProcessCannotDeliver() throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let session = UUID().uuidString
        try store.publishSession(id: session, label: "Temporary", pid: getpid())
        let expired = try store.offerContext(sender: "Peer", sessionID: session, body: "Old offer", requestID: "first")
        try store.reviewContext(id: expired, approve: true)
        try store.db.execute("UPDATE context_offers SET created = unixepoch() - 90000 WHERE id = ?", [expired])
        XCTAssertTrue(try store.takeContext(sessionID: session).isEmpty)
        XCTAssertEqual(try store.contextInbox().first?.state, "stale")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let dead = UUID().uuidString
        try store.publishSession(id: dead, label: "Child process", pid: process.processIdentifier)
        let queued = try store.offerContext(sender: "Peer", sessionID: dead, body: "For child", requestID: "second")
        try store.reviewContext(id: queued, approve: true)
        XCTAssertTrue(try store.takeContext(sessionID: dead).isEmpty)
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(try store.publishedSessions().contains(where: { $0.id == dead.lowercased() }))
        XCTAssertEqual(try store.contextInbox().first(where: { $0.id == queued })?.state, "stale")
    }

    func testSimultaneousRetriesAndTakesAcrossConnections() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let session = UUID().uuidString
        try store.publishSession(id: session, label: "Concurrent", pid: getpid())
        let ids = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try Store(directory: directory).offerContext(sender: "Peer", sessionID: session, body: "Same", requestID: "same")
                }
            }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(Set(ids).count, 1)
        let offer = try XCTUnwrap(ids.first)
        try store.reviewContext(id: offer, approve: true)
        let taken = try await withThrowingTaskGroup(of: [ContextOffer].self, returning: [ContextOffer].self) { group in
            for _ in 0..<4 {
                group.addTask { try Store(directory: directory).takeContext(sessionID: session) }
            }
            var results: [ContextOffer] = []
            for try await value in group { results.append(contentsOf: value) }
            return results
        }
        XCTAssertEqual(taken.map(\.id), [offer])
    }

    func testLeaseExpiresWhileProcessLivesAndRenewsOnlyOnOwnerRead() throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let session = UUID().uuidString.lowercased()
        try store.publishSession(id: session, label: "Idle conversation", pid: getpid())
        try store.db.execute("UPDATE shared_sessions SET lease_until = unixepoch() + 10 WHERE id = ?", [session])
        let offer = try store.offerContext(sender: "Peer", sessionID: session, body: "Waiting", requestID: "lease")
        XCTAssertEqual(try store.publishedSessions().map(\.id), [session])
        XCTAssertEqual(try store.offerStatus(sender: "Peer", requestID: "lease"), "pending")
        XCTAssertEqual(try store.db.query("SELECT lease_until < unixepoch() + 20 FROM shared_sessions") {
            Database.string($0, 0)
        }.first, "1")
        XCTAssertTrue(try store.takeContext(sessionID: session).isEmpty)
        XCTAssertEqual(try store.db.query("SELECT lease_until > unixepoch() + 1740 FROM shared_sessions") {
            Database.string($0, 0)
        }.first, "1")

        try store.reviewContext(id: offer, approve: true)
        try store.db.execute("UPDATE shared_sessions SET lease_until = unixepoch() - 1 WHERE id = ?", [session])
        XCTAssertTrue(try store.takeContext(sessionID: session).isEmpty)
        XCTAssertTrue(try store.publishedSessions().isEmpty)
        XCTAssertEqual(try store.offerStatus(sender: "Peer", requestID: "lease"), "expired")
        XCTAssertThrowsError(try store.publishSession(id: session, label: "Expired", pid: getpid()))
    }

    private func temporaryLibrary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
