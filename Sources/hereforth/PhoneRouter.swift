import Foundation
import HereforthCore
import WebAuthn

struct PhoneHTTPResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data
    var cookie: String?

    static func json(_ data: Data, status: Int = 200) -> Self {
        Self(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ status: Int, _ message: String) -> Self {
        .json((try? JSONEncoder().encode(["error": message])) ?? Data(), status: status)
    }
}

actor PhoneRouter {
    private struct Failure: Error {
        let status: Int
        let message: String
        init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    }

    private enum Purpose: Sendable {
        case register
        case login
        case approval(session: UUID, action: String, payload: Data)
    }

    private struct Ceremony: Sendable {
        let challenge: [UInt8]
        let purpose: Purpose
        let expires: Date
        let generation: UUID
    }

    private struct Start<Options: Encodable>: Encodable {
        let challengeId: UUID
        let options: Options
    }

    private struct Finish<Credential: Decodable>: Decodable {
        let challengeId: UUID
        let credential: Credential
    }

    private static let cookieName = "__Host-hereforth-phone"
    private static let sessionLifetime = 8 * 60 * 60
    private static let readActions: Set<String> = ["activity", "get_task", "inbox", "list_peers", "list_briefs",
                                                   "preview_work", "preview_standup", "list_peer_sessions", "preview_handoff"]
    private static let verifiedActions: Set<String> = ["review_context", "review_work", "review_standup", "send_handoff", "queue_task"]

    private let configuration: PhoneConfiguration
    private let webAuthn: WebAuthnManager
    private let actions: PhoneActions
    private var pending: [UUID: Ceremony] = [:]

    init(configuration: PhoneConfiguration, actions: PhoneActions) {
        self.configuration = configuration
        self.actions = actions
        webAuthn = WebAuthnManager(configuration: .init(
            relyingPartyID: configuration.domain, relyingPartyName: "Hereforth", relyingPartyOrigin: configuration.origin
        ))
    }

    func response(request: PhoneHTTPRequest, body: Data) async -> PhoneHTTPResponse {
        guard request.headers["host"] == configuration.authority,
              request.headers["x-forwarded-host"] == configuration.authority,
              request.headers["x-forwarded-proto"] == "https",
              request.headers["tailscale-user-login"] == configuration.owner,
              request.headers["tailscale-funnel-request"] == nil,
              request.headers["authorization"] == nil else {
            return .error(403, "Open this page through the configured private Tailscale Serve origin.")
        }
        do {
            let state = try checkedState()
            let now = Date()
            pending = pending.filter { $0.value.expires > now && $0.value.generation == state.generation }
            let cookie = Self.cookieDigest(request.headers["cookie"])
            let session = state.session(digest: cookie, at: now)
            if request.method == "GET", body.isEmpty {
                return try get(request.path, state: state, session: session)
            }
            guard request.method == "POST" else { throw Failure(405, "This method is unavailable.") }
            guard request.headers["origin"] == configuration.origin,
                  request.headers["sec-fetch-site"] == nil || request.headers["sec-fetch-site"] == "same-origin" else {
                throw Failure(403, "Open the private page directly before sending a request.")
            }
            guard let type = request.headers["content-type"]?.lowercased(),
                  type == "application/json" || type == "application/json; charset=utf-8",
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw Failure(400, "Send a JSON object.")
            }
            switch request.path {
            case "/api/auth/register/start":
                guard let code = object["code"] as? String, object.count == 1 else { throw Failure(400, "Enter the Mac’s pairing code.") }
                return try beginRegistration(code: code, at: now)
            case "/api/auth/register/finish":
                guard Set(object.keys) == ["challengeId", "credential"] else { throw Failure(400, "Send only the passkey response.") }
                return try await finishRegistration(body)
            case "/api/auth/login/start":
                guard object.isEmpty else { throw Failure(400, "Send an empty sign-in request.") }
                return try beginAuthentication(state: state, purpose: .login, passkeys: state.passkeys, now: now)
            case "/api/auth/login/finish":
                guard Set(object.keys) == ["challengeId", "credential"] else { throw Failure(400, "Send only the passkey response.") }
                return try finishAuthentication(body, expectedSession: nil)
            case "/api/auth/logout":
                guard object.isEmpty else { throw Failure(400, "Send an empty sign-out request.") }
                if let session {
                    try updateState { $0.sessions.removeAll { $0.id == session.id } }
                }
                var response = try encode(["authenticated": false])
                response.cookie = Self.cookie(value: "", maxAge: 0)
                return response
            default:
                guard let session else { throw Failure(401, "Sign in with your Hereforth passkey.") }
                if request.path == "/api/auth/approve/start" {
                    guard object.count == 2, let name = object["action"] as? String,
                          Self.verifiedActions.contains(name), let parameters = object["payload"] as? [String: Any] else {
                        throw Failure(400, "Choose an available preview or approval.")
                    }
                    let payload = try JSONSerialization.data(withJSONObject: parameters, options: .sortedKeys)
                    return try beginAuthentication(state: state, purpose: .approval(session: session.id, action: name, payload: payload),
                                                   passkeys: state.passkeys.filter { $0.id == session.passkeyID }, now: now)
                }
                if request.path == "/api/auth/approve/finish" {
                    guard Set(object.keys) == ["challengeId", "credential"] else { throw Failure(400, "Send only the passkey response.") }
                    return try finishAuthentication(body, expectedSession: session)
                }
                let prefix = "/api/actions/"
                if request.path.hasPrefix(prefix) {
                    let name = String(request.path.dropFirst(prefix.count))
                    if Self.verifiedActions.contains(name) { throw Failure(403, "Verify this change with your passkey.") }
                    if Self.readActions.contains(name) { return try perform(name, payload: body) }
                }
                throw Failure(404, "This page is unavailable.")
            }
        } catch let failure as Failure {
            return .error(failure.status, failure.message)
        } catch {
            return .error(503, "Hereforth could not complete the request.")
        }
    }

    private func get(_ path: String, state: PhoneState, session: PhoneState.Session?) throws -> PhoneHTTPResponse {
        if path == "/api/session" { return try encode(["authenticated": session != nil, "passkey": !state.passkeys.isEmpty]) }
        let assets = [
            "/": ("index.html", "text/html; charset=utf-8"),
            "/app.js": ("app.js", "application/javascript; charset=utf-8"),
            "/styles.css": ("styles.css", "text/css; charset=utf-8")
        ]
        guard let (filename, type) = assets[path] else { throw Failure(404, "This page is unavailable.") }
        guard let asset = PhoneWebAssets.load(filename) else {
            throw Failure(503, "The installed app is missing its phone page.")
        }
        return PhoneHTTPResponse(status: 200, contentType: type, body: asset)
    }

    private func beginRegistration(code: String, at now: Date) throws -> PhoneHTTPResponse {
        guard pending.count < 32 else { throw Failure(429, "Wait for the previous passkey prompt to expire.") }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "")
        guard PhoneSecrets.valid(code, length: 32) else { throw Failure(401, "This pairing code is missing, expired, or already used.") }
        let accepted: (epoch: UUID, user: UUID)? = try updateState { state in
            guard var invite = state.invitation, invite.expires > now else { return nil }
            guard PhoneSecrets.equal(invite.digest, PhoneSecrets.digest(code)), state.passkeys.count < 8 else {
                invite.failures += 1
                state.invitation = invite.failures < 8 ? invite : nil
                return nil
            }
            state.invitation = nil
            return (state.generation, state.userID)
        }
        guard let accepted else { throw Failure(401, "This pairing code is missing, expired, or already used.") }
        let options = webAuthn.beginRegistration(
            user: .init(id: Array(accepted.user.uuidString.utf8), name: "owner", displayName: "Hereforth owner"),
            timeout: .seconds(90),
            authenticatorSelection: .init(residentKey: .required, userVerification: .required)
        )
        let id = addCeremony(options.challenge, purpose: .register, epoch: accepted.epoch, now: now)
        return try encode(Start(challengeId: id, options: options))
    }

    private func finishRegistration(_ body: Data) async throws -> PhoneHTTPResponse {
        let request: Finish<RegistrationCredential> = try decode(body)
        guard let ceremony = takeCeremony(request.challengeId), case .register = ceremony.purpose else {
            throw Failure(401, "Start a new passkey registration.")
        }
        let credential: Credential
        do {
            guard request.credential.id.decodedBytes == request.credential.rawID else { throw Failure(401, "Could not verify the passkey.") }
            credential = try await webAuthn.finishRegistration(
                challenge: ceremony.challenge, credentialCreationData: request.credential, requireUserVerification: true,
                confirmCredentialIDNotRegisteredYet: { _ in true }
            )
        } catch {
            throw Failure(401, "Could not verify the passkey.")
        }
        guard let id = Data(base64Encoded: credential.id), id == Data(request.credential.rawID), !id.isEmpty else {
            throw Failure(401, "Could not verify the passkey.")
        }
        let token = try PhoneSecrets.token(byteCount: 32)
        try updateState { state in
            guard state.generation == ceremony.generation, state.passkeys.count < 8,
                  !state.passkeys.contains(where: { $0.credential == id }) else {
                throw Failure(409, "This passkey cannot be enrolled. Check the phone status on your Mac.")
            }
            let key = PhoneState.Passkey(id: UUID(), credential: id, publicKey: Data(credential.publicKey), created: .now, signCount: credential.signCount)
            state.passkeys.append(key)
            try Self.issueSession(state: &state, passkey: key.id, token: token)
        }
        return try authenticated(token)
    }

    private func beginAuthentication(state: PhoneState, purpose: Purpose, passkeys: [PhoneState.Passkey],
                                     now: Date) throws -> PhoneHTTPResponse {
        guard !passkeys.isEmpty else { throw Failure(401, "Pair a phone at the Mac first.") }
        guard pending.count < 32 else { throw Failure(429, "Wait for the previous passkey prompt to expire.") }
        let options = webAuthn.beginAuthentication(
            timeout: .seconds(90), allowCredentials: passkeys.map { PublicKeyCredentialDescriptor(id: Array($0.credential)) },
            userVerification: .required
        )
        let id = addCeremony(options.challenge, purpose: purpose, epoch: state.generation, now: now)
        return try encode(Start(challengeId: id, options: options))
    }

    private func finishAuthentication(_ body: Data, expectedSession: PhoneState.Session?) throws -> PhoneHTTPResponse {
        let request: Finish<AuthenticationCredential> = try decode(body)
        guard let ceremony = takeCeremony(request.challengeId),
              request.credential.id.decodedBytes == request.credential.rawID else {
            throw Failure(401, "Start a new passkey prompt.")
        }
        let token = expectedSession == nil ? try PhoneSecrets.token(byteCount: 32) : nil
        try updateState { state in
            guard state.generation == ceremony.generation,
                  request.credential.response.userHandle == nil ||
                    request.credential.response.userHandle == Array(state.userID.uuidString.utf8),
                  let index = state.passkeys.firstIndex(where: { $0.credential == Data(request.credential.rawID) }) else {
                throw Failure(401, "Could not verify the passkey.")
            }
            let key = state.passkeys[index]
            switch ceremony.purpose {
            case .login where expectedSession == nil: break
            case let .approval(sessionID, _, _):
                guard let expectedSession, expectedSession.id == sessionID, expectedSession.passkeyID == key.id,
                      state.session(digest: expectedSession.digest, at: .now)?.id == sessionID else {
                    throw Failure(401, "Start a new passkey prompt for this change.")
                }
            default: throw Failure(401, "Start a new passkey prompt.")
            }
            do {
                let verified = try webAuthn.finishAuthentication(
                    credential: request.credential, expectedChallenge: ceremony.challenge, credentialPublicKey: Array(key.publicKey),
                    credentialCurrentSignCount: key.signCount, requireUserVerification: true
                )
                state.passkeys[index].signCount = verified.newSignCount
            } catch {
                throw Failure(401, "Could not verify the passkey.")
            }
            if let token { try Self.issueSession(state: &state, passkey: key.id, token: token) }
        }
        if let token { return try authenticated(token) }
        if case let .approval(_, name, payload) = ceremony.purpose { return try perform(name, payload: payload) }
        throw Failure(401, "Start a new passkey prompt.")
    }

    private func perform(_ action: String, payload: Data) throws -> PhoneHTTPResponse {
        do { return .json(try actions.handle(action, payload: payload)) }
        catch let error as HereforthError { throw Failure(409, error.localizedDescription) }
        catch is DecodingError { throw Failure(400, "Check the details and try again.") }
        catch { throw Failure(503, "Hereforth could not complete this action.") }
    }

    private func checkedState() throws -> PhoneState {
        let state = try PhoneStateStore.read()
        guard state.configuration == configuration else { throw Failure(503, "Restart phone access on the Mac.") }
        return state
    }

    private func updateState<Value>(_ change: (inout PhoneState) throws -> Value) throws -> Value {
        try PhoneStateStore.update { state in
            guard state.configuration == configuration else { throw Failure(503, "Restart phone access on the Mac.") }
            return try change(&state)
        }
    }

    private func addCeremony(_ challenge: [UInt8], purpose: Purpose, epoch: UUID, now: Date) -> UUID {
        let id = UUID()
        pending[id] = Ceremony(challenge: challenge, purpose: purpose, expires: now.addingTimeInterval(90), generation: epoch)
        return id
    }

    private func takeCeremony(_ id: UUID) -> Ceremony? {
        guard let ceremony = pending.removeValue(forKey: id), ceremony.expires > .now else { return nil }
        return ceremony
    }

    private static func issueSession(state: inout PhoneState, passkey: UUID, token: String) throws {
        guard state.sessions.count < 16 else { throw Failure(409, "Revoke an unused session on your Mac and try again.") }
        state.sessions.append(.init(id: UUID(), passkeyID: passkey, digest: PhoneSecrets.digest(token),
                                    expires: .now.addingTimeInterval(TimeInterval(sessionLifetime))))
    }

    private static func cookieDigest(_ header: String?) -> Data? {
        guard let header else { return nil }
        let candidates = header.split(separator: ";").compactMap { part -> String? in
            let value = part.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(cookieName + "=") else { return nil }
            return String(value.dropFirst(cookieName.count + 1))
        }
        guard candidates.count == 1, let token = candidates.first, PhoneSecrets.valid(token, length: 64) else { return nil }
        return PhoneSecrets.digest(token)
    }

    private static func cookie(value: String, maxAge: Int) -> String {
        "\(cookieName)=\(value); Path=/; Max-Age=\(maxAge); Secure; HttpOnly; SameSite=Strict"
    }

    private func authenticated(_ token: String) throws -> PhoneHTTPResponse {
        var response = try encode(["authenticated": true])
        response.cookie = Self.cookie(value: token, maxAge: Self.sessionLifetime)
        return response
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> PhoneHTTPResponse {
        .json(try JSONEncoder().encode(value))
    }

    private func decode<Value: Decodable>(_ body: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: body) }
        catch { throw Failure(400, "The passkey response has an invalid format.") }
    }
}
