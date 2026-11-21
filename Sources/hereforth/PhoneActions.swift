import CoreFoundation
import Foundation
import HereforthCore

struct PhoneActions {
    typealias Object = [String: Any]
    let store: Store

    func handle(_ action: String, payload: Data) throws -> Data {
        guard let input = try JSONSerialization.jsonObject(with: payload) as? Object else {
            throw HereforthError("Expected a JSON action object.")
        }
        let allowed: [String: Set<String>] = [
            "activity": [], "inbox": [], "list_peers": [], "list_briefs": [], "get_task": ["id"],
            "list_peer_sessions": ["peer"], "preview_work": ["id", "brief_id"],
            "review_context": ["id", "digest", "approve"],
            "review_work": ["id", "digest", "approve", "brief_id", "revision_digest"],
            "preview_standup": ["id", "approved_text"], "review_standup": ["id", "digest", "approved_text"],
            "preview_handoff": ["brief_id", "peer", "session_id", "request_id"],
            "send_handoff": ["id", "digest"], "queue_task": ["request_id", "client", "kind", "prompt"]
        ]
        guard let keys = allowed[action], Set(input.keys).isSubset(of: keys) else {
            throw HereforthError("Unknown phone action or unexpected input.")
        }
        func required(_ key: String) throws -> String {
            guard let value = input[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HereforthError("Complete the \(key) field.")
            }
            return value
        }
        func approval() throws -> Bool {
            guard let value = input["approve"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw HereforthError("Choose approve or decline.")
            }
            return value.boolValue
        }
        let output: Object
        switch action {
        case "activity":
            output = try activity()
        case "get_task":
            return try JSONEncoder().encode(store.ownerTask(id: required("id")))
        case "inbox":
            let contexts = try store.contextInbox().lazy.filter { $0.state == "pending" }.prefix(100).map(contextRow)
            let requests = try store.workRequests().lazy.filter { $0.state == "pending" }.prefix(100).map(workRow)
            output = ["items": Array(contexts) + Array(requests)]
        case "list_peers":
            output = ["peers": try PeerSettings.load().names().prefix(100).map { ["name": $0] }]
        case "list_briefs":
            output = ["briefs": try store.briefs().prefix(100).map { ["id": $0.id, "title": $0.title, "recipient": $0.recipient] }]
        case "list_peer_sessions":
            let destination = try peer(required("peer"))
            output = ["sessions": try sessions(destination.target).map { ["id": $0.id, "label": $0.label] }]
        case "review_context":
            let id = try required("id")
            let approval = try approval()
            let expected = try required("digest")
            let initial = try context(id)
            guard contextDigest(initial) == expected else { throw changed() }
            let matching = approval ? ["approved", "consumed"] : ["declined"]
            if !matching.contains(initial.state) {
                do { try store.reviewContext(id: id, approve: approval) }
                catch {
                    guard try matching.contains(context(id).state) else { throw error }
                }
            }
            output = ["id": id, "state": try context(id).state]
        case "preview_work":
            let preview = try store.previewWorkRequest(id: required("id"), briefID: required("brief_id"))
            output = ["briefID": preview.briefID, "title": preview.title, "markdown": preview.markdown,
                      "digest": preview.digest, "sender": preview.sender,
                      "scope": "Read only this exact brief revision for seven days."]
        case "review_work":
            let request = try work(required("id"))
            guard try workDigest(request) == required("digest") else { throw changed() }
            let choice = try approval()
            let target = try input["brief_id"].map { _ in try required("brief_id") }
            let revision = try input["revision_digest"].map { _ in try required("revision_digest") }
            let saved = try store.reviewWorkRequest(id: request.id, approve: choice, briefID: target, digest: revision)
            output = ["id": saved.id, "state": saved.state, "receipt": saved.receipt]
        case "preview_standup", "review_standup":
            let request = try work(required("id"))
            let text = try required("approved_text")
            guard request.requestsStandup, text.utf8.count <= 12_000 else {
                throw HereforthError("Review an explicit standup request and up to 12,000 bytes of update text.")
            }
            let digest = hash("standup-review-v1", workDigest(request), text)
            if action == "preview_standup" {
                guard request.state == "pending" else { throw changed() }
                output = ["id": request.id, "digest": digest, "approvedText": text, "sender": request.sender,
                          "scope": "Open a private standup thread for this requester for seven days."]
            } else {
                guard try digest == required("digest") else { throw changed() }
                let thread = try store.reviewStandupRequest(id: request.id, approvedText: text)
                output = ["id": request.id, "state": "fulfilled", "threadID": thread.id, "expiresAt": thread.expiresAt]
            }
        case "preview_handoff":
            let destination = try peer(required("peer"))
            guard let sessionID = try UUID(uuidString: required("session_id")),
                  let session = try sessions(destination.target).first(where: { UUID(uuidString: $0.id) == sessionID }) else {
                throw HereforthError("Choose a named session currently published by the paired recipient.")
            }
            let preview = try store.preparePhoneHandoff(briefID: required("brief_id"), peer: destination.name,
                                                       sessionID: sessionID.uuidString.lowercased(), sessionLabel: session.label,
                                                       destinationKey: destination.key, requestID: required("request_id"))
            output = handoffRow(preview)
        case "send_handoff":
            let draft = try store.phoneHandoff(required("id"))
            let expected = try required("digest")
            guard draft.digest == expected else { throw changed() }
            if draft.state == "sent" {
                output = handoffRow(draft)
            } else {
                let destination = try peer(draft.peer)
                let ready = try store.startPhoneHandoff(id: draft.id, digest: expected, destinationKey: destination.key)
                if ready.state == "sent" {
                    output = handoffRow(ready)
                } else {
                    let offer = PeerOffer(session_id: ready.sessionID, body: ready.markdown, request_id: ready.id)
                    let result = try PeerSettings.request(target: destination.target, path: "v1/offers",
                                                          payload: JSONEncoder().encode(offer))
                    let response = try JSONDecoder().decode([String: String].self, from: result)
                    guard let receipt = response["offer_id"] else {
                        throw HereforthError("The paired recipient did not confirm the handoff.")
                    }
                    output = try handoffRow(store.recordPhoneHandoffDelivery(id: ready.id, receipt: receipt))
                }
            }
        case "queue_task":
            let task = try store.queueOwnerTask(requestID: required("request_id"), client: required("client"),
                                                kind: required("kind"), prompt: required("prompt"))
            return try JSONEncoder().encode(task)
        default:
            throw HereforthError("Unknown phone action.")
        }
        return try JSONSerialization.data(withJSONObject: output)
    }

    func activity() throws -> Object {
        let sessions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.assistantSessions()))
        let tasks = try store.ownerTasks().map { task -> Object in
            let description = String(task.prompt.prefix(240))
            return ["id": task.id, "client": task.client, "kind": task.kind, "state": task.state,
             "createdAt": task.createdAt, "updatedAt": task.updatedAt,
             "description": description, "descriptionTruncated": !task.prompt.utf8.elementsEqual(description.utf8)]
        }
        return ["sessions": sessions, "tasks": tasks,
                "instructions": "Published means the local connector lease is active. Session progress is assistant-reported when available. Task intents require local review and a user-operated launch. Provider execution status is unavailable."]
    }

    private func context(_ id: String) throws -> ContextOffer {
        guard let offer = try store.contextInbox().first(where: { $0.id == id }) else {
            throw HereforthError("This context offer is unavailable.")
        }
        return offer
    }

    private func work(_ id: String) throws -> WorkRequest {
        guard let task = try store.workRequests().first(where: { $0.id == id }) else {
            throw HereforthError("This work request is unavailable.")
        }
        return task
    }

    private func contextRow(_ offer: ContextOffer) -> Object {
        ["id": offer.id, "kind": "context", "sender": offer.sender, "label": offer.sessionLabel,
         "body": offer.body, "digest": contextDigest(offer), "requestsBrief": false, "requestsStandup": false,
         "scope": "Permit this text once in the published session \(offer.sessionLabel)."]
    }

    private func workRow(_ request: WorkRequest) -> Object {
        var row: Object = ["id": request.id, "kind": "work", "sender": request.sender, "label": request.category,
                           "body": request.body, "digest": workDigest(request), "requestsBrief": request.requestsBrief,
                           "requestsStandup": request.requestsStandup,
                           "scope": "Record local review. No external action is performed."]
        if let briefID = request.briefID { row["briefID"] = briefID }
        if request.requestsBrief { row["scope"] = "Grant this requester read access to one reviewed brief revision for seven days." }
        if request.requestsStandup { row["scope"] = "Share one reviewed update in a private standup thread for seven days." }
        return row
    }

    private func handoffRow(_ draft: PhoneHandoff) -> Object {
        var row = ["id": draft.id, "briefID": draft.briefID, "title": draft.title, "markdown": draft.markdown,
                   "peer": draft.peer, "sessionID": draft.sessionID, "sessionLabel": draft.sessionLabel,
                   "digest": draft.digest, "state": draft.state]
        if let receipt = draft.receipt { row["receipt"] = receipt }
        return row
    }

    private func contextDigest(_ offer: ContextOffer) -> String {
        hash("context-review-v1", offer.id, offer.sender, offer.sessionID, offer.sessionLabel, offer.body)
    }

    private func workDigest(_ request: WorkRequest) -> String {
        hash("work-review-v1", request.id, request.sender, request.category, request.body,
             String(request.requestsBrief), String(request.requestsStandup))
    }

    private func hash(_ parts: String...) -> String {
        PeerSettings.hash(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }

    private func changed() -> HereforthError {
        HereforthError("The reviewed preview changed. Open it again before confirming.")
    }

    private func peer(_ name: String) throws -> (name: String, target: PeerSettings.Peer, key: String) {
        let settings = try PeerSettings.load()
        let exact = try settings.resolve(name)
        guard let target = settings.peers[exact] else { throw HereforthError("This peer is not paired.") }
        return (exact, target, hash("phone-peer-v1", exact, target.url.absoluteString, target.token))
    }

    private func sessions(_ target: PeerSettings.Peer) throws -> [SharedSession] {
        let data = try PeerSettings.request(target: target, path: "v1/sessions")
        return Array(try JSONDecoder().decode([SharedSession].self, from: data).prefix(50))
    }
}
