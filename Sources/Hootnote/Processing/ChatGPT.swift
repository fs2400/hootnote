import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Sign in with ChatGPT: summaries and answers from your own ChatGPT Plus or Pro plan, with no API key.
/// This is OpenAI's flow for open-source apps that run locally (developers.openai.com/siwc): a client
/// registered on first sign-in, PKCE, and a redirect back to 127.0.0.1. Tokens are kept in the Keychain.
@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()

    struct Model: Identifiable, Hashable {
        let slug: String
        let displayName: String
        var id: String { slug }
    }

    /// The signed-in account's email, or nil when signed out.
    @Published private(set) var email: String?
    /// Whether the account let Hootnote use its ChatGPT plan (the chatgpt.tokens.use.direct scope).
    @Published private(set) var planUsageGranted = false
    @Published private(set) var models: [Model] = []
    @Published private(set) var signingIn = false

    var isSignedIn: Bool { email != nil && planUsageGranted }
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    private static let issuer = "https://auth.openai.com"
    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let apiBase = URL(string: "https://api.openai.com/v1")!
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let registrationClientID = "dynamic_agent_client"
    private static let callbackPath = "/auth/callback"

    /// What the Keychain holds. The client ID and account stay after signing out, for the next sign-in.
    private struct Credentials: Codable {
        var clientID: String
        var subject: String
        var email: String?
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String] = []
    }

    private var credentials: Credentials? {
        didSet {
            email = credentials?.refreshToken == nil ? nil : credentials?.email ?? "your ChatGPT account"
            planUsageGranted = credentials?.scopes.contains(Self.planScope) ?? false
        }
    }
    private var refreshing: Task<String, Error>?
    private static let keychain = KeychainItem(service: "com.local.Hootnote.chatgpt", account: "credentials")

    private init() {
        if let data = Self.keychain.read(), let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = saved
            email = saved.refreshToken == nil ? nil : saved.email ?? "your ChatGPT account"
            planUsageGranted = saved.scopes.contains(Self.planScope)
        }
    }

    // MARK: Signing in and out

    /// The sign-in waiting for the browser, if any.
    private var pendingSignIn: LoopbackServer?

    /// Stops waiting for the browser, for when ChatGPT's page ends without sending you back
    /// (for example when a workspace admin hasn't allowed Hootnote).
    func cancelSignIn() {
        pendingSignIn?.cancel()
    }

    func signIn() async throws {
        guard !signingIn else { return }
        signingIn = true
        defer { signingIn = false }

        let server = try await LoopbackServer.start()
        pendingSignIn = server
        defer {
            server.stop()
            pendingSignIn = nil
        }
        let redirectURI = "http://127.0.0.1:\(server.port)\(Self.callbackPath)"
        let verifier = Self.randomToken(), state = Self.randomToken(), nonce = Self.randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let saved = credentials

        var query: [(String, String)] = [
            ("client_id", saved?.clientID ?? Self.registrationClientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", Self.scopes),
            ("resource", Self.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            ("ext_agent_host_id", Self.hostID),
        ]
        if let saved {
            if let idToken = saved.idToken { query.append(("id_token_hint", idToken)) }
            if let email = saved.email { query.append(("login_hint", email)) }
        } else {
            query.append(("agent_name_hint", "Hootnote"))
        }
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&")
        server.expect(state: state)
        NSWorkspace.shared.open(components.url!)

        let callback = try await server.waitForCallback(timeout: 300)
        if let error = callback["error"] {
            throw error == "access_denied" ? ChatGPTError.cancelled : ChatGPTError.server(callback["error_description"] ?? error)
        }
        guard let code = callback["code"] else { throw ChatGPTError.server("ChatGPT didn't return a sign-in code.") }

        // A first sign-in registers this copy of Hootnote; ChatGPT returns the new client ID with the code.
        let clientID: String
        if let saved {
            if let returned = callback["client_id"], returned != saved.clientID { throw ChatGPTError.server("ChatGPT returned a different app registration.") }
            clientID = saved.clientID
        } else {
            guard let issued = callback["client_id"], issued != Self.registrationClientID,
                  issued.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil else {
                throw ChatGPTError.server("ChatGPT didn't finish registering Hootnote. Try again.")
            }
            clientID = issued
        }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI, "resource": Self.resource,
        ])
        guard let idToken = tokens["id_token"] as? String,
              let claims = Self.verifiedClaims(idToken, clientID: clientID, nonce: nonce),
              let subject = claims["sub"] as? String else {
            throw ChatGPTError.server("ChatGPT's sign-in response couldn't be verified.")
        }
        if let saved, saved.subject != subject {
            // Another ChatGPT account: it needs a registration of its own, so start fresh next time.
            credentials = nil
            Self.keychain.delete()
            throw ChatGPTError.server("That's a different ChatGPT account from last time. Select Continue with ChatGPT again to use it.")
        }
        var fresh = Credentials(clientID: clientID, subject: subject, email: claims["email"] as? String ?? saved?.email, idToken: idToken)
        apply(tokens, to: &fresh)
        save(fresh)
        guard planUsageGranted else { throw ChatGPTError.planUsageNotGranted }
        try? await loadModels()
    }

    /// Ends the session with OpenAI, then forgets the tokens (keeping the registration for next time).
    func signOut() async {
        if let c = credentials, let refresh = c.refreshToken, let endpoint = await Self.revocationEndpoint() {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formBody(["token": refresh, "token_type_hint": "refresh_token", "client_id": c.clientID])
            req.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: req)
        }
        guard var c = credentials else { return }
        c.accessToken = nil
        c.refreshToken = nil
        c.idToken = nil
        c.expiresAt = nil
        save(c)
        models = []
    }

    // MARK: Models and requests

    func loadModels() async throws {
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("models"))
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        models = list.compactMap { m in
            guard m["visibility"] as? String == "list", let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
            return Model(slug: slug, displayName: (m["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug)
        }
    }

    /// The chosen model if the account still offers it, otherwise the first one ChatGPT lists.
    func model(preferring slug: String) async throws -> Model {
        if models.isEmpty { try await loadModels() }
        guard let model = models.first(where: { $0.slug == slug }) ?? models.first else {
            throw ChatGPTError.server("ChatGPT didn't offer any models for this account.")
        }
        return model
    }

    /// Streams one answer from the Responses API. `input` is the conversation so far (user and assistant turns).
    func respond(model: String, instructions: String, input: [ChatMessage],
                 onText: ((String) -> Void)? = nil) async throws -> String {
        do {
            return try await stream(model: model, instructions: instructions, input: input, onText: onText)
        } catch ChatGPTError.unauthorized {
            // The access token was refused: refresh once, then give up.
            credentials?.expiresAt = .distantPast
            return try await stream(model: model, instructions: instructions, input: input, onText: onText)
        }
    }

    private func stream(model: String, instructions: String, input: [ChatMessage],
                        onText: ((String) -> Void)?) async throws -> String {
        var req = URLRequest(url: Self.apiBase.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The plan route requires store false and stream true, and rejects temperature and output limits.
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": instructions,
            "input": input.map { ["role": $0.role, "content": $0.content] },
            "store": false,
            "stream": true,
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try Self.check(response, data)
        }
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    text += delta
                    onText?(delta)
                }
            case "response.completed":
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "response.failed":
                throw Self.apiError(from: (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? [:], status: 0)
            case "response.incomplete":
                throw ChatGPTError.server("ChatGPT stopped before finishing the answer.")
            case "error":
                throw Self.apiError(from: event["error"] as? [String: Any] ?? event, status: 0)
            default:
                continue
            }
        }
        throw ChatGPTError.server("The connection to ChatGPT ended before the answer was complete.")
    }

    // MARK: Tokens

    /// A current access token, refreshed when it's about to expire. Refreshes run one at a time,
    /// because each one replaces the refresh token.
    private func accessToken() async throws -> String {
        guard let c = credentials, c.refreshToken != nil else { throw ChatGPTError.notSignedIn }
        guard c.scopes.contains(Self.planScope) else { throw ChatGPTError.planUsageNotGranted }
        if let token = c.accessToken, let expiry = c.expiresAt, expiry > Date().addingTimeInterval(60) { return token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard var c = credentials, let refreshToken = c.refreshToken else { throw ChatGPTError.notSignedIn }
        let tokens: [String: Any]
        do {
            tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": c.clientID,
                                             "refresh_token": refreshToken, "resource": Self.resource])
        } catch ChatGPTError.tokenRejected {
            c.accessToken = nil
            c.refreshToken = nil
            save(c)
            throw ChatGPTError.signInExpired
        }
        apply(tokens, to: &c)
        save(c)  // Saved at once: the old refresh token no longer works.
        guard let token = c.accessToken else { throw ChatGPTError.signInExpired }
        return token
    }

    private func apply(_ tokens: [String: Any], to c: inout Credentials) {
        if let access = tokens["access_token"] as? String { c.accessToken = access }
        if let refresh = tokens["refresh_token"] as? String { c.refreshToken = refresh }
        if let id = tokens["id_token"] as? String { c.idToken = id }
        if let seconds = (tokens["expires_in"] as? NSNumber)?.doubleValue { c.expiresAt = Date().addingTimeInterval(seconds) }
        if let scope = tokens["scope"] as? String { c.scopes = scope.split(separator: " ").map(String.init) }
    }

    private func save(_ c: Credentials) {
        credentials = c
        if let data = try? JSONEncoder().encode(c) { Self.keychain.write(data) }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = json["error"] as? String ?? (json["error"] as? [String: Any])?["code"] as? String ?? ""
            let unusable = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                            "refresh_token_invalidated", "refresh_token_reused"]
            if unusable.contains(code) { throw ChatGPTError.tokenRejected }
            throw ChatGPTError.server(json["error_description"] as? String ?? (code.isEmpty ? "Sign-in failed." : code))
        }
        return json
    }

    /// The ID token's claims, after checking issuer, audience, expiry and nonce. It came straight from
    /// the token endpoint over TLS, which OpenID Connect Core 3.1.3.7 accepts in place of a signature check.
    private static func verifiedClaims(_ jwt: String, clientID: String, nonce: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        let audience = claims["aud"] as? [String] ?? [(claims["aud"] as? String) ?? ""]
        let expiry = (claims["exp"] as? NSNumber)?.doubleValue ?? 0
        guard claims["iss"] as? String == issuer, audience.contains(clientID), claims["nonce"] as? String == nonce,
              expiry > Date().timeIntervalSince1970 - 5, (claims["azp"] as? String).map({ $0 == clientID }) ?? true
        else { return nil }
        return claims
    }

    private static func revocationEndpoint() async -> URL? {
        guard let url = URL(string: "https://auth.openai.com/.well-known/openid-configuration"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let endpoint = (json["revocation_endpoint"] as? String).flatMap(URL.init(string:)),
              endpoint.host == "auth.openai.com" else { return nil }
        return endpoint
    }

    // MARK: Helpers

    /// One opaque ID per copy of Hootnote, kept for every sign-in (OpenAI's ext_agent_host_id).
    private static var hostID: String {
        let key = "chatgptHostID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        Data(fields.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").utf8)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] { throw apiError(from: error, status: http.statusCode) }
        if http.statusCode == 401 { throw ChatGPTError.unauthorized }
        throw ChatGPTError.server(json["detail"] as? String ?? "ChatGPT returned HTTP \(http.statusCode).")
    }

    private static func apiError(from error: [String: Any], status: Int) -> ChatGPTError {
        let code = error["code"] as? String ?? ""
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_invalid_user": return .unauthorized
        default:
            if status == 401 { return .unauthorized }
            return .server(error["message"] as? String ?? (code.isEmpty ? "ChatGPT couldn't answer." : code))
        }
    }
}

enum ChatGPTError: LocalizedError {
    case notSignedIn, planUsageNotGranted, signInExpired, cancelled, usageLimit, notEligible, unauthorized, tokenRejected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to ChatGPT in Settings › AI."
        case .planUsageNotGranted: return "ChatGPT didn't let Hootnote use your plan. Sign in again in Settings › AI and allow it."
        case .signInExpired, .unauthorized, .tokenRejected: return "Your ChatGPT sign-in has expired. Sign in again in Settings › AI."
        case .cancelled: return "ChatGPT sign-in was cancelled."
        case .usageLimit: return "You've reached your ChatGPT plan's usage limit for now. See chatgpt.com/settings/usage."
        case .notEligible: return "This ChatGPT account can't be used in other apps. It needs a Plus or Pro plan."
        case .server(let message): return "ChatGPT: \(message)"
        }
    }
}

/// Waits on 127.0.0.1 for the browser to come back from ChatGPT's sign-in page.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Hootnote.chatgpt-callback")
    private(set) var port: UInt16 = 0
    private var expectedState = ""
    private var starting: CheckedContinuation<Void, Error>?
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// A callback that arrived before anyone was waiting for it.
    private var received: [String: String]?

    private init(listener: NWListener) { self.listener = listener }

    /// Listens on OpenAI's example port, 1455, or any free port if that one's taken (only the port may vary).
    static func start() async throws -> LoopbackServer {
        do { return try await start(port: 1455) } catch { return try await start(port: 0) }
    }

    private static func start(port: UInt16) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let server = LoopbackServer(listener: try NWListener(using: parameters))
        server.listener.stateUpdateHandler = { [weak server] state in server?.stateChanged(state) }
        server.listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
        do {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
                server.queue.async {
                    server.starting = ready
                    server.listener.start(queue: server.queue)
                }
            }
        } catch {
            server.stop()
            throw error
        }
        return server
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            starting?.resume()
        case .failed(let error), .waiting(let error):
            starting?.resume(throwing: error)
        default:
            return
        }
        starting = nil
    }

    func expect(state: String) { queue.sync { expectedState = state } }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.finish(.failure(ChatGPTError.server("Sign-in timed out. Try again.")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let received = self.received {
                    self.received = nil
                    continuation.resume(returning: received)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func stop() { listener.cancel() }

    func cancel() { finish(.failure(ChatGPTError.cancelled)) }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            self.continuation?.resume(with: result)
            self.continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            guard components?.path == "/auth/callback" else { return self.reply(connection, 404, "Not found.") }
            var fields: [String: String] = [:]
            for item in components?.queryItems ?? [] { fields[item.name] = item.value ?? "" }
            // A wrong state isn't ours: answer it, but keep waiting for the real callback.
            guard !self.expectedState.isEmpty, fields["state"] == self.expectedState else {
                return self.reply(connection, 400, "This sign-in link doesn't match. Go back to Hootnote and try again.")
            }
            let failed = fields["error"] != nil
            self.reply(connection, 200, failed ? "Sign-in was cancelled. You can close this tab."
                                               : "You're signed in. You can close this tab and go back to Hootnote.")
            if let continuation = self.continuation {
                continuation.resume(returning: fields)
                self.continuation = nil
            } else {
                self.received = fields
            }
        }
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ message: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>Hootnote</title>
        <body style="font: 16px -apple-system, sans-serif; margin: 4em auto; max-width: 32em">\(message)</body>
        """
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
