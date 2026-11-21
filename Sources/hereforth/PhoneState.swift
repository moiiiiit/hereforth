import CryptoKit
import Darwin
import Foundation
import HereforthCore
import Security

struct PhoneConfiguration: Codable, Equatable, Sendable {
    let origin: String
    let authority: String
    let domain: String
    let owner: String
    let port: UInt16

    init(origin: String, owner: String, port: UInt16) throws {
        guard let parts = URLComponents(string: origin), parts.scheme == "https",
              let domain = parts.host?.lowercased(), domain.utf8.count <= 253,
              domain.hasSuffix(".ts.net"), domain.split(separator: ".", omittingEmptySubsequences: false).count >= 4,
              domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(Self.validLabel),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65_535).contains(parts.port ?? 0), port > 0,
              (1...254).contains(owner.utf8.count), owner.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }) else {
            throw HereforthError("Use the private HTTPS Serve origin and the exact Tailscale login of the owner.")
        }
        let authority = parts.port.flatMap { $0 == 443 ? nil : domain + ":" + String($0) } ?? domain
        self.origin = "https://" + authority
        self.authority = authority
        self.domain = domain
        self.owner = owner
        self.port = port
    }

    private static func validLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}

struct PhoneState: Codable {
    struct Invite: Codable {
        let digest: Data
        let expires: Date
        var failures = 0
    }

    struct Passkey: Codable, Sendable {
        let id: UUID
        let credential: Data
        let publicKey: Data
        let created: Date
        var signCount: UInt32
    }

    struct Session: Codable, Sendable {
        let id: UUID
        let passkeyID: UUID
        let digest: Data
        let expires: Date
    }

    var configuration: PhoneConfiguration?
    var generation = UUID()
    var userID = UUID()
    var invitation: Invite?
    var passkeys: [Passkey] = []
    var sessions: [Session] = []

    func session(digest: Data?, at now: Date) -> Session? {
        guard let digest else { return nil }
        return sessions.first { session in
            PhoneSecrets.equal(session.digest, digest) && session.expires > now && passkeys.contains { $0.id == session.passkeyID }
        }
    }
}

enum PhoneSecrets {
    static func token(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard result == errSecSuccess else { throw HereforthError("Could not create a private phone credential.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func digest(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { result, bytes in result | (bytes.0 ^ bytes.1) } == 0
    }
}

enum PhoneStateStore {
    private static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["HEREFORTH_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hereforth", isDirectory: true)
    }
    private static var location: URL { directory.appendingPathComponent("phone-auth.json") }

    static func read() throws -> PhoneState {
        let fd = open(location.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return PhoneState() }
        guard fd >= 0 else { throw HereforthError("Could not open private phone settings.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard isPrivateFile(fd), let bytes = try file.read(upToCount: 65_537), bytes.count <= 65_536 else {
            throw HereforthError("The phone settings need owner-only permissions.")
        }
        return try JSONDecoder().decode(PhoneState.self, from: bytes)
    }

    static func update<Value>(_ change: (inout PhoneState) throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent("phone-auth.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HereforthError("Could not open the phone settings lock.") }
        defer { close(fd) }
        guard isPrivateFile(fd), flock(fd, LOCK_EX) == 0 else { throw HereforthError("Could not lock the phone settings.") }
        var state = try read()
        let now = Date()
        state.sessions.removeAll { $0.expires <= now }
        if let invitation = state.invitation, invitation.expires <= now { state.invitation = nil }
        let result = try change(&state)
        try JSONEncoder().encode(state).write(to: location, options: .atomic)
        return result
    }

    private static func isPrivateFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == geteuid() &&
            info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0
    }
}
