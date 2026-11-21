import Darwin
import Foundation
import HereforthCore
import Network

struct PhoneHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let length: Int

    init?(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let start = lines.first else { return nil }
        let parts = start.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].hasPrefix("/"), parts[1].utf8.count <= 128,
              parts[1].utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) ||
                  (48...57).contains($0) || [45, 46, 47, 95].contains($0) }) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = line[..<colon].lowercased()
            let raw = line[line.index(after: colon)...]
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  raw.utf8.allSatisfy({ (32...126).contains($0) || $0 == 9 }), headers[name] == nil else { return nil }
            headers[name] = raw.trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil, headers["upgrade"] == nil else { return nil }
        let value = headers["content-length"] ?? "0"
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(value), length <= 65_536 else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        self.headers = headers
        self.length = length
    }
}

final class PhoneListener {
    private let listener: NWListener
    private let router: PhoneRouter
    private let queue = DispatchQueue(label: "hereforth.phone.listener")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var failed = false

    init(port: UInt16, router: PhoneRouter) throws {
        let parameters = NWParameters.tcp
        guard let endpoint = NWEndpoint.Port(rawValue: port), port > 0 else { throw HereforthError("Use a valid local phone port.") }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpoint)
        listener = try NWListener(using: parameters)
        self.router = router
    }

    func run(parent: Int32?) throws {
        let stopped = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: FileHandle.standardOutput.write(Data("ready\n".utf8))
            case .failed:
                self?.failed = true
                stopped.signal()
            case .cancelled: stopped.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        let timer = parent.map { expected -> DispatchSourceTimer in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in if getppid() != expected { self?.listener.cancel() } }
            timer.resume()
            return timer
        }
        stopped.wait()
        timer?.cancel()
        if failed { throw HereforthError("Phone access could not bind to its local port.") }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections[identifier] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 16) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            let invalid = PhoneHTTPResponse.error(400, "Invalid phone request.")
            guard bytes.count <= 77_828 else { self.send(connection, invalid); return }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if bytes.count > 12_288 || done { self.send(connection, invalid) }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            guard end.lowerBound <= 12_288,
                  let head = String(data: bytes.prefix(upTo: end.lowerBound), encoding: .ascii),
                  let request = PhoneHTTPRequest(head) else { self.send(connection, invalid); return }
            let body = bytes.suffix(from: end.upperBound)
            guard body.count == request.length else {
                if body.count > request.length || done { self.send(connection, invalid) }
                else { self.receive(connection, buffer: bytes) }
                return
            }
            Task {
                let response = await self.router.response(request: request, body: body)
                self.send(connection, response)
            }
        }
    }

    private func send(_ connection: NWConnection, _ response: PhoneHTTPResponse) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 429: reason = "Too Many Requests"
        default: reason = "Service Unavailable"
        }
        var lines = [
            "HTTP/1.1 \(response.status) \(reason)", "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)", "Connection: close", "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "X-Frame-Options: DENY",
            "Strict-Transport-Security: max-age=31536000",
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
            "Permissions-Policy: publickey-credentials-create=(self), publickey-credentials-get=(self), camera=(), microphone=(), geolocation=()"
        ]
        if let cookie = response.cookie { lines.append("Set-Cookie: " + cookie) }
        var bytes = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        bytes.append(response.body)
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
