import CryptoKit
import Darwin
import Foundation
import HereforthCore
import Security

struct PeerOffer: Codable {
    let session_id: String
    let body: String
    let request_id: String
}

struct PeerStatus: Codable {
    let request_id: String
}

struct PeerWorkRequest: Codable {
    static let categories = WorkRequestCategory.allCases.map(\.rawValue)

    let request_id: String
    let category: String
    let body: String
    let brief_id: String?
    let requests_brief: Bool?
    let requests_standup: Bool?
}

struct PeerStandupList: Codable { let offset: Int }

struct PeerStandupRead: Codable {
    let thread_id: String
    let after: Int
}

struct PeerStandupReply: Codable {
    let thread_id: String
    let request_id: String
    let body: String
}

struct PeerSettings: Codable {
    struct Peer: Codable {
        let url: URL
        let token: String
    }

    var invites: [String: String] = [:]
    var peers: [String: Peer] = [:]

    static var location: URL {
        let root = ProcessInfo.processInfo.environment["HEREFORTH_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hereforth")
        return root.appendingPathComponent("peer-settings.json")
    }

    static func load() throws -> Self {
        let fd = open(location.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return Self() }
        guard fd >= 0 else { throw HereforthError("Could not open the private peer configuration.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard privateFile(fd), let data = try handle.read(upToCount: 256_001), data.count <= 256_000 else {
            throw HereforthError("The peer configuration needs owner-only permissions and a valid size.")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private static func privateFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == geteuid() &&
            info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0
    }

    private static func update(_ change: (inout Self) -> Void) throws {
        umask(0o077)
        let directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("peer-settings.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HereforthError("Could not open the peer configuration lock.") }
        defer { close(fd) }
        guard privateFile(fd), flock(fd, LOCK_EX) == 0 else {
            throw HereforthError("Could not lock the private peer configuration.")
        }
        var settings = try load()
        change(&settings)
        let data = try JSONEncoder().encode(settings)
        guard data.count <= 256_000 else { throw HereforthError("Remove unused peers or invitations before adding more.") }
        try data.write(to: location, options: .atomic)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func endpoint(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && host == "127.0.0.1"),
              let url = parts.url else {
            throw HereforthError("Enter an HTTPS origin or an HTTP origin on 127.0.0.1.")
        }
        return url
    }

    static func command(_ arguments: [String]) throws {
        switch arguments.first {
        case "serve" where (1...2).contains(arguments.count):
            let portText = arguments.count == 2 ? arguments[1] : "9124"
            guard let port = UInt16(portText), port > 0 else { throw HereforthError("Enter a valid TCP port.") }
            try PeerListener(store: Store(), port: port).run()
        case "invite" where arguments.count == 2:
            let name = try label(arguments[1])
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else { throw HereforthError("Could not generate a peer invitation.") }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            try update { $0.invites[name] = hash(token) }
            print(token)
        case "revoke" where arguments.count == 2:
            let name = try label(arguments[1])
            try update { $0.invites.removeValue(forKey: name) }
        case "remove" where arguments.count == 2:
            let name = try label(arguments[1])
            try update { $0.peers.removeValue(forKey: name) }
        case "add" where arguments.count == 3:
            let name = try label(arguments[1])
            let url = try endpoint(arguments[2])
            if isatty(STDIN_FILENO) == 1 { throw HereforthError("Provide the invitation token through standard input.") }
            guard let token = readLine(), validToken(token) else { throw HereforthError("Enter the invitation token through standard input.") }
            try update { $0.peers[name] = Peer(url: url, token: token) }
        default:
            throw HereforthError("Use peer serve [PORT], peer invite SENDER, peer revoke SENDER, peer add PEER URL, or peer remove PEER.")
        }
    }

    private static func label(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HereforthError("Enter a peer name of 1–100 bytes without control characters.")
        }
        return name
    }

    static func request(peer: String, path: String, payload: Data? = nil) throws -> Data {
        guard let target = try load().peers[peer] else { throw HereforthError("This peer has not been configured.") }
        guard validToken(target.token) else { throw HereforthError("The configured peer token is invalid.") }
        let origin = try endpoint(target.url.absoluteString)
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 8)
        request.setValue("Bearer " + target.token, forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let result = PeerResponse()
        let session = URLSession(configuration: configuration, delegate: result, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard result.ready.wait(timeout: .now() + 10) == .success else { throw HereforthError("The peer request timed out.") }
        if result.tooLarge { throw HereforthError("The peer response exceeded the size limit.") }
        if result.failed { throw HereforthError("Could not complete the peer request.") }
        guard let status = result.status else { throw HereforthError("Could not reach the peer service.") }
        if status == 401 { throw HereforthError("The peer rejected the invitation token.") }
        if status == 409 { throw HereforthError("The peer could not accept the request. Check the destination and reuse a request UUID only for a matching retry.") }
        guard status == 200 else {
            throw HereforthError("The peer did not return a valid response.")
        }
        return result.data
    }
}

private final class PeerResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 1_048_576
    let ready = DispatchSemaphore(value: 0)
    private(set) var data = Data()
    private(set) var status: Int?
    private(set) var failed = false
    private(set) var tooLarge = false

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        tooLarge = response.expectedContentLength > Self.limit
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !tooLarge, data.count <= Self.limit - self.data.count else {
            tooLarge = true
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        failed = error != nil
        ready.signal()
    }
}
