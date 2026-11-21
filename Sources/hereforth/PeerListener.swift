import Foundation
import HereforthCore
import Network

final class PeerListener {
    private let store: Store
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hereforth.peer")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let port: UInt16

    init(store: Store, port: UInt16) throws {
        self.store = store
        self.port = port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func run() throws {
        let finished = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                writeError("Hereforth peer service listening on 127.0.0.1:\(self.port)")
            case .failed, .cancelled:
                finished.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        finished.wait()
        throw HereforthError("The local peer listener stopped. Check the requested port.")
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard connections.count < 48 else {
            connection.cancel()
            return
        }
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            guard bytes.count <= 24_576 else { self.send(connection, status: 413); return }

            guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if bytes.count > 8_192 || done { self.send(connection, status: 400) }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            guard separator.lowerBound <= 8_192,
                  let head = String(data: bytes.prefix(upTo: separator.lowerBound), encoding: .ascii),
                  let request = Request(head), request.length <= 16_384 else {
                self.send(connection, status: 400)
                return
            }
            let body = bytes.suffix(from: separator.upperBound)
            guard body.count == request.length else {
                if body.count > request.length || done { self.send(connection, status: 400) }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            self.handle(connection, request: request, body: body)
        }
    }

    private func handle(_ connection: NWConnection, request: Request, body: Data) {
        do {
            guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer ") else {
                send(connection, status: 401)
                return
            }
            let token = String(authorization.dropFirst(7))
            guard PeerSettings.validToken(token) else {
                send(connection, status: 401)
                return
            }
            let digest = PeerSettings.hash(token)
            guard let label = try PeerSettings.load().invites.first(where: { $0.value == digest })?.key else {
                send(connection, status: 401)
                return
            }
            // The invitation owns its history even when a later invitation reuses the label.
            let sender = "\(label) [hf-pair:\(digest.prefix(32))]"
            switch (request.method, request.path) {
            case ("GET", "/v1/sessions") where request.length == 0:
                let sessions = Array(try store.publishedSessions().prefix(50))
                send(connection, status: 200, body: try JSONEncoder().encode(sessions))
            case ("POST", "/v1/offers"):
                guard request.headers["content-type"] == "application/json",
                      let offer = try? JSONDecoder().decode(PeerOffer.self, from: body),
                      let requestID = UUID(uuidString: offer.request_id) else {
                    send(connection, status: 400)
                    return
                }
                do {
                    let id = try store.offerContext(sender: sender, sessionID: offer.session_id,
                                                    body: offer.body, requestID: requestID.uuidString)
                    send(connection, status: 200, body: try JSONEncoder().encode(["offer_id": id, "state": "submitted"]))
                } catch {
                    send(connection, status: 409)
                }
            case ("POST", "/v1/status"):
                guard request.headers["content-type"] == "application/json",
                      let query = try? JSONDecoder().decode(PeerStatus.self, from: body),
                      let requestID = UUID(uuidString: query.request_id) else {
                    send(connection, status: 400)
                    return
                }
                let state = try store.offerStatus(sender: sender, requestID: requestID.uuidString) ?? "unknown"
                send(connection, status: 200, body: try JSONEncoder().encode(["state": state]))
            case ("POST", "/v1/work-requests"):
                guard request.headers["content-type"] == "application/json",
                      let work = try? JSONDecoder().decode(PeerWorkRequest.self, from: body),
                      let requestID = UUID(uuidString: work.request_id),
                      PeerWorkRequest.categories.contains(work.category), work.body.utf8.count <= 4_000,
                      work.brief_id == nil || UUID(uuidString: work.brief_id ?? "") != nil,
                      (work.brief_id == nil && work.requests_brief != true && work.requests_standup != true) || work.category == "data_access" else {
                    send(connection, status: 400)
                    return
                }
                do {
                    let id = try store.submitWorkRequest(sender: sender, requestID: requestID.uuidString,
                                                         category: work.category, body: work.body, briefID: work.brief_id,
                                                         requestsBrief: work.requests_brief ?? false, requestsStandup: work.requests_standup ?? false)
                    send(connection, status: 200, body: try JSONEncoder().encode(["id": id]))
                } catch {
                    send(connection, status: 409)
                }
            case ("POST", "/v1/work-status"), ("POST", "/v1/work-grant"):
                guard request.headers["content-type"] == "application/json",
                      let query = try? JSONDecoder().decode(PeerStatus.self, from: body),
                      let requestID = UUID(uuidString: query.request_id) else {
                    send(connection, status: 400)
                    return
                }
                let encoder = JSONEncoder()
                let data: Data
                if request.path == "/v1/work-status" {
                    data = try encoder.encode(store.workRequestStatus(sender: sender, requestID: requestID.uuidString))
                } else {
                    data = try encoder.encode(store.readWorkRequestGrant(sender: sender, requestID: requestID.uuidString))
                }
                send(connection, status: 200, body: data)
            case ("POST", "/v1/standup-threads"):
                guard request.headers["content-type"] == "application/json",
                      let query = try? JSONDecoder().decode(PeerStandupList.self, from: body), query.offset >= 0 else {
                    send(connection, status: 400)
                    return
                }
                let threads = try store.peerStandupThreads(sender: sender, offset: query.offset)
                send(connection, status: 200, body: try JSONEncoder().encode(threads))
            case ("POST", "/v1/standup-read"):
                guard request.headers["content-type"] == "application/json",
                      let query = try? JSONDecoder().decode(PeerStandupRead.self, from: body),
                      UUID(uuidString: query.thread_id) != nil, query.after >= 0 else {
                    send(connection, status: 400)
                    return
                }
                let messages = try store.peerStandupMessages(sender: sender, threadID: query.thread_id, after: query.after)
                send(connection, status: 200, body: try JSONEncoder().encode(messages))
            case ("POST", "/v1/standup-reply"):
                guard request.headers["content-type"] == "application/json",
                      let reply = try? JSONDecoder().decode(PeerStandupReply.self, from: body),
                      UUID(uuidString: reply.thread_id) != nil, UUID(uuidString: reply.request_id) != nil,
                      reply.body.utf8.count <= 4_000 else {
                    send(connection, status: 400)
                    return
                }
                do {
                    let saved = try store.replyToPeerStandup(sender: sender, threadID: reply.thread_id,
                                                           body: reply.body, requestID: reply.request_id)
                    send(connection, status: 200, body: try JSONEncoder().encode(saved))
                } catch {
                    send(connection, status: 409)
                }
            default:
                send(connection, status: 404)
            }
        } catch {
            send(connection, status: 503)
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data = Data()) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Service Unavailable"
        }
        var data = Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n" +
                         "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let length: Int

        init?(_ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let words = first.components(separatedBy: " ")
            guard words.count == 3, words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0" else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { return nil }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { return nil }
            let value = headers["content-length"] ?? "0"
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(value) else { return nil }
            method = words[0]
            path = words[1]
            self.length = length
            self.headers = headers
        }
    }
}
