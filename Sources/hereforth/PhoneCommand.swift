import Darwin
import Foundation
import HereforthCore

enum PhoneCommand {
    private struct Status: Encodable {
        let configured: Bool
        let origin: String?
        let port: UInt16?
        let owner: String?
        let passkeys: [Passkey]
        let sessions: [Session]

        struct Passkey: Encodable {
            let id: UUID
            let created: Date
        }

        struct Session: Encodable {
            let id: UUID
            let expires: Date
        }
    }

    static func run(_ arguments: [String]) throws {
        _ = umask(0o077)
        switch arguments.first {
        case "configure" where (3...4).contains(arguments.count):
            let portText = arguments.count == 4 ? arguments[3] : "9125"
            guard let port = UInt16(portText) else { throw HereforthError("Use a valid local phone port.") }
            let configuration = try PhoneConfiguration(origin: arguments[1], owner: arguments[2], port: port)
            try PhoneStateStore.update { state in
                if state.configuration != configuration {
                    state = PhoneState()
                    state.configuration = configuration
                }
            }
            print("Configured private phone access on 127.0.0.1:\(port).")
        case "serve" where arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--parent-pid"):
            let parent: Int32?
            if arguments.count == 3 {
                guard let pid = Int32(arguments[2]), pid > 1, pid == getppid() else {
                    throw HereforthError("The phone server must belong to its launching process.")
                }
                parent = pid
            } else { parent = nil }
            guard let configuration = try PhoneStateStore.read().configuration else {
                throw HereforthError("Configure the private phone origin first.")
            }
            let router = PhoneRouter(configuration: configuration, actions: PhoneActions(store: try Store()))
            try PhoneListener(port: configuration.port, router: router).run(parent: parent)
        case "pair" where arguments.count == 1:
            guard isatty(STDOUT_FILENO) == 1 else { throw HereforthError("Pairing codes are shown only in a local terminal.") }
            let token = try PhoneSecrets.token(byteCount: 16)
            try PhoneStateStore.update {
                guard $0.configuration != nil else { throw HereforthError("Configure the private phone origin first.") }
                guard $0.passkeys.count < 8 else { throw HereforthError("Revoke an unused passkey before enrolling another.") }
                $0.invitation = .init(digest: PhoneSecrets.digest(token), expires: .now.addingTimeInterval(300))
            }
            print("Phone pairing code: \(token)")
            print("Enter it on your private Hereforth phone page within five minutes.")
        case "status" where arguments.count == 1:
            let state = try PhoneStateStore.read()
            let status = Status(configured: state.configuration != nil, origin: state.configuration?.origin,
                                port: state.configuration?.port, owner: state.configuration?.owner,
                                passkeys: state.passkeys.map { .init(id: $0.id, created: $0.created) },
                                sessions: state.sessions.filter { $0.expires > .now }.map { .init(id: $0.id, expires: $0.expires) })
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(status), as: UTF8.self))
        case "revoke", "revoke-passkey":
            guard arguments.count == 2 else { throw HereforthError("Enter an ID from phone status or all.") }
            let all = arguments[1] == "all"
            let identifier = UUID(uuidString: arguments[1])
            guard all || identifier != nil else { throw HereforthError("Enter an ID from phone status or all.") }
            try PhoneStateStore.update { state in
                if all {
                    state.generation = UUID()
                    state.invitation = nil
                }
                if arguments[0] == "revoke-passkey" {
                    state.passkeys.removeAll { all || $0.id == identifier }
                    state.sessions.removeAll { all || $0.passkeyID == identifier }
                } else {
                    state.sessions.removeAll { all || $0.id == identifier }
                }
            }
            print("Revoked phone access for the selected entries.")
        default:
            throw HereforthError("Use phone configure, serve, pair, status, revoke, or revoke-passkey.")
        }
    }
}
