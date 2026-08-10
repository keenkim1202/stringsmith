import CryptoKit
import Darwin
import Foundation

// MARK: - 토큰

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// 만료 60초 전부터 만료로 친다.
    ///
    /// 딱 맞춰 판단하면 검사와 요청 도착 사이에 만료가 지나 401 이 날 수 있다.
    public func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}

// MARK: - 토큰 저장소

public protocol TokenStore: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func clear() throws
}

/// 홈 디렉터리의 파일에 둔다.
///
/// 키체인이 아닌 이유는 이 도구가 **서명되지 않은 바이너리로 배포**되기 때문이다. 키체인
/// 항목의 접근 권한은 코드 서명에 묶여 있어서, 서명이 없으면 릴리스마다 — 때로는 빌드마다 —
/// 사용자에게 허용 창을 다시 띄운다. `gcloud`·`aws` 도 같은 이유로 0600 파일을 쓴다.
/// P6 에서 공증까지 붙고 나면 키체인으로 옮길 수 있다.
public struct FileTokenStore: TokenStore {
    public let path: String

    public init(path: String = FileTokenStore.defaultPath) {
        self.path = path
    }

    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.config/stringsmith/credentials.json"
    }

    public func load() throws -> OAuthTokens? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            // 형식이 깨진 파일은 로그인하면 덮어쓰면 된다. 여기서 죽이지 않는다.
            return nil
        }
    }

    public func save(_ tokens: OAuthTokens) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = try JSONEncoder().encode(tokens)
        try data.write(to: URL(fileURLWithPath: path))
        // write(to:) 는 기존 파일의 권한을 유지하므로 매번 다시 좁힌다.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}

/// 테스트용.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> OAuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: OAuthTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}

// MARK: - PKCE

/// RFC 7636. 인가 코드가 가로채여도 verifier 없이는 토큰으로 바꿀 수 없게 한다.
///
/// 데스크톱 앱은 클라이언트 비밀값을 비밀로 지킬 수 없으므로, 실질적인 방어는 이쪽이다.
public struct PKCE: Sendable {
    public let verifier: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        self.verifier = Data(bytes).base64URLEncoded
    }

    public init(verifier: String) {
        self.verifier = verifier
    }

    public var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

// MARK: - loopback 서버

/// 브라우저가 돌려주는 인가 코드를 받을 임시 서버.
///
/// Google 은 2022년에 복사·붙여넣기(OOB) 방식을 폐지해서, 설치형 앱은 loopback 으로 받아야
/// 한다. 포트는 0 으로 bind 해 커널이 비어 있는 걸 고르게 한다 — 고정 포트를 쓰면 이미 뭔가
/// 물려 있을 때 로그인이 통째로 막힌다.
final class LoopbackServer {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        // 지역 변수로 다 만든 뒤에 저장한다. 저장 프로퍼티를 클로저에서 먼저 건드리면
        // "all members were initialized" 전에 self 를 캡처하는 게 되어 컴파일되지 않는다.
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw LoopbackServer.failure("socket()") }

        var enable: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // 커널이 고른다
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw LoopbackServer.failure("bind()")
        }
        guard listen(handle, 4) == 0 else {
            close(handle)
            throw LoopbackServer.failure("listen()")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(handle, $0, &length)
            }
        }

        descriptor = handle
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit { close(descriptor) }

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// 인가 코드가 담긴 요청 하나를 기다린다.
    ///
    /// 브라우저는 `/favicon.ico` 처럼 관계없는 요청도 보내므로, `code` 나 `error` 가 붙은
    /// 요청이 올 때까지 계속 받는다.
    func waitForCode(state: String, deadline: Date) throws -> String {
        while Date() < deadline {
            var incoming = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&incoming, 1, 500) > 0 else { continue }

            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }

            guard let target = readRequestTarget(client) else {
                respond(client, status: "400 Bad Request", body: "")
                continue
            }
            guard let components = URLComponents(string: "http://127.0.0.1" + target) else {
                respond(client, status: "400 Bad Request", body: "")
                continue
            }
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }

            if let denied = value("error") {
                respond(client, status: "200 OK", body: Self.page(success: false))
                throw StringsmithError.io(
                    path: "OAuth",
                    reason: tr(
                        "Google returned \"\(denied)\" — the request was declined.",
                        "Google 이 \"\(denied)\" 를 돌려줬습니다 — 요청이 거부되었습니다."))
            }

            guard let code = value("code") else {
                // favicon 등. 무시하고 계속 기다린다.
                respond(client, status: "404 Not Found", body: "")
                continue
            }

            // state 가 다르면 우리가 시작한 로그인이 아니다.
            guard value("state") == state else {
                respond(client, status: "200 OK", body: Self.page(success: false))
                throw StringsmithError.io(
                    path: "OAuth",
                    reason: tr(
                        "The reply did not match this login request (state mismatch).",
                        "이 로그인 요청과 맞지 않는 응답입니다 (state 불일치)."))
            }

            respond(client, status: "200 OK", body: Self.page(success: true))
            return code
        }

        throw StringsmithError.io(
            path: "OAuth",
            reason: tr(
                """
                Timed out waiting for the browser.
                  → Finish the Google sign-in in the browser window, then run the command again.
                """,
                """
                브라우저 응답을 기다리다 시간이 지났습니다.
                  → 브라우저에서 Google 로그인을 마친 뒤 명령을 다시 실행하세요.
                """))
    }

    // MARK: 소켓 입출력

    private func readRequestTarget(_ client: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return nil }

        let request = String(decoding: buffer[0..<count], as: UTF8.self)
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first,
            line.hasPrefix("GET ")
        else { return nil }

        let target = line.dropFirst(4).prefix { $0 != " " }
        return target.isEmpty ? nil : String(target)
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(payload.count)\r
            Connection: close\r
            \r

            """
        var out = Data(head.utf8)
        out.append(payload)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(client, base.advanced(by: written), raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// 브라우저에서 보게 될 화면.
    ///
    /// **"로그인되었습니다" 라고 쓰지 않는다.** 이 페이지는 인가 코드를 받은 시점에 나가고,
    /// 토큰 교환은 그 뒤에 일어난다. 성공을 단언했다가 교환이 실패하면 브라우저와 터미널이
    /// 서로 다른 말을 하게 된다 — 실제로 한 번 그렇게 어긋났다. 판정은 터미널이 한다.
    static func page(success: Bool) -> String {
        let title =
            success
            ? tr("Returning to the terminal", "터미널로 돌아가세요")
            : tr("Sign-in failed", "로그인하지 못했습니다")
        let detail =
            success
            ? tr(
                "You can close this tab. The terminal will show whether it worked.",
                "이 탭을 닫아도 됩니다. 성공 여부는 터미널에 표시됩니다.")
            : tr("Return to the terminal for details.", "자세한 내용은 터미널을 보세요.")
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>stringsmith</title></head>
            <body style="font-family:-apple-system,sans-serif;text-align:center;padding:4rem 1rem">
            <h1 style="font-size:1.4rem;margin:0 0 .5rem">\(title)</h1>
            <p style="color:#666;margin:0">\(detail)</p>
            </body></html>
            """
    }

    private static func failure(_ call: String) -> StringsmithError {
        .io(
            path: "127.0.0.1",
            reason: tr(
                "Could not open a local port for the sign-in reply (\(call)).",
                "로그인 응답을 받을 로컬 포트를 열지 못했습니다 (\(call))."))
    }
}

// MARK: - Google OAuth

public struct GoogleOAuth: Sendable {
    public let clientID: String
    public let clientSecret: String?
    let fetch: HTTPFetch

    static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    public init(
        clientID: String = GoogleClient.id,
        clientSecret: String? = GoogleClient.secret,
        fetch: @escaping HTTPFetch = performRequest
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.fetch = fetch
    }

    // MARK: 인가 URL

    public func authorizationURL(redirectURI: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: Self.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleClient.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // refresh token 을 받으려면 둘 다 필요하다. prompt 를 빼면 두 번째 로그인부터
            // refresh token 이 오지 않아 다음 실행에서 조용히 재로그인을 요구하게 된다.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    // MARK: 토큰 교환·갱신

    public func exchange(code: String, verifier: String, redirectURI: String) throws -> OAuthTokens
    {
        var parameters = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let clientSecret { parameters["client_secret"] = clientSecret }

        let response = try post(parameters)
        guard let refreshToken = response.refreshToken else {
            throw StringsmithError.io(
                path: "OAuth",
                reason: tr(
                    """
                    Google did not return a refresh token.
                      → Revoke stringsmith at https://myaccount.google.com/permissions
                        and sign in again.
                    """,
                    """
                    Google 이 refresh token 을 주지 않았습니다.
                      → https://myaccount.google.com/permissions 에서 stringsmith 접근을
                        해제한 뒤 다시 로그인하세요.
                    """))
        }
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn))
    }

    public func refresh(_ tokens: OAuthTokens) throws -> OAuthTokens {
        var parameters = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ]
        if let clientSecret { parameters["client_secret"] = clientSecret }

        let response = try post(parameters)
        return OAuthTokens(
            // 갱신 응답에는 refresh token 이 없다. 갖고 있던 걸 유지한다.
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn))
    }

    /// 저장된 토큰을 쓰되 만료가 가까우면 갱신하고 저장한다.
    public func validAccessToken(store: TokenStore, now: Date = Date()) throws -> String {
        guard let tokens = try store.load() else {
            throw StringsmithError.io(path: "OAuth", reason: Self.notSignedIn)
        }
        guard tokens.isExpired(at: now) else { return tokens.accessToken }

        let renewed = try refresh(tokens)
        try store.save(renewed)
        return renewed.accessToken
    }

    static var notSignedIn: String {
        tr(
            """
            Not signed in to Google.
              → Run: ss auth login
            """,
            """
            Google 에 로그인되어 있지 않습니다.
              → 실행: ss auth login
            """)
    }

    // MARK: 로그인 흐름

    /// 브라우저를 열고, 돌아온 코드를 토큰으로 바꿔 저장한다.
    ///
    /// `openURL` 과 `announce` 를 주입받는 건 테스트 때문만이 아니다 — 브라우저를 여는
    /// 방식은 실행 환경마다 다르고, Core 가 그걸 정하면 안 된다.
    @discardableResult
    public func login(
        store: TokenStore,
        timeout: TimeInterval = 300,
        openURL: (URL) throws -> Void,
        announce: (String) -> Void = { _ in }
    ) throws -> OAuthTokens {
        guard !clientID.isEmpty else {
            throw StringsmithError.invalidConfiguration(
                path: "OAuth", reason: GoogleClient.notConfiguredMessage)
        }

        let server = try LoopbackServer()
        let pkce = PKCE()
        let state = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded

        guard
            let url = authorizationURL(
                redirectURI: server.redirectURI, challenge: pkce.challenge, state: state)
        else {
            throw StringsmithError.invalidConfiguration(
                path: "OAuth",
                reason: tr("Could not build the sign-in URL.", "로그인 주소를 만들지 못했습니다."))
        }

        announce(
            tr(
                "Opening the browser to sign in to Google…",
                "Google 로그인을 위해 브라우저를 엽니다…"))
        try openURL(url)
        announce(
            tr(
                "  If it did not open, visit:\n  \(url.absoluteString)",
                "  열리지 않으면 이 주소로 접속하세요:\n  \(url.absoluteString)"))

        let code = try server.waitForCode(
            state: state, deadline: Date().addingTimeInterval(timeout))
        let tokens = try exchange(
            code: code, verifier: pkce.verifier, redirectURI: server.redirectURI)
        try store.save(tokens)
        return tokens
    }

    // MARK: 토큰 엔드포인트

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenError: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func post(_ parameters: [String: String]) throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw StringsmithError.io(path: Self.tokenEndpoint, reason: "bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(parameters)

        let response = try fetch(request)
        guard response.status == 200 else {
            throw StringsmithError.io(
                path: Self.tokenEndpoint, reason: Self.explain(response))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw StringsmithError.io(
                path: Self.tokenEndpoint,
                reason: tr(
                    "Could not read the token response.", "토큰 응답을 해석하지 못했습니다."))
        }
    }

    /// 구글의 오류 코드는 짧아서 그대로 보여주면 무엇을 해야 할지 알 수 없다.
    static func explain(_ response: SheetResponse) -> String {
        let parsed = try? JSONDecoder().decode(TokenError.self, from: response.body)
        let code = parsed?.error ?? "HTTP \(response.status)"

        // 구글은 비밀값이 빠졌을 때 invalid_client 가 아니라 invalid_request 로 답하고,
        // 진짜 이유는 error_description 에만 적어 준다. 실제로 이 경로로 한 번 막혔다.
        if parsed?.errorDescription?.contains("client_secret") == true {
            return tr(
                """
                This OAuth client requires a secret (\(code)).
                  → Google Cloud Console → Credentials → your Desktop client,
                    then set it and try again:
                      export STRINGSMITH_GOOGLE_CLIENT_SECRET=…
                """,
                """
                비밀값을 요구하는 OAuth 클라이언트입니다 (\(code)).
                  → Google Cloud Console → 사용자 인증 정보 → 데스크톱 클라이언트에서 확인한 뒤
                    설정하고 다시 시도하세요:
                      export STRINGSMITH_GOOGLE_CLIENT_SECRET=…
                """)
        }

        switch parsed?.error {
        case "invalid_grant":
            return tr(
                """
                The saved sign-in is no longer valid (\(code)).
                  → It expires if unused for six months, or after the password changes.
                  → Run: ss auth login
                """,
                """
                저장된 로그인이 더 이상 유효하지 않습니다 (\(code)).
                  → 6개월간 쓰지 않거나 비밀번호를 바꾸면 만료됩니다.
                  → 실행: ss auth login
                """)
        case "invalid_client":
            return tr(
                """
                Google rejected the OAuth client (\(code)).
                  → The client may require a secret. Set it and try again:
                      export STRINGSMITH_GOOGLE_CLIENT_SECRET=…
                """,
                """
                Google 이 OAuth 클라이언트를 거부했습니다 (\(code)).
                  → 비밀값을 요구하는 클라이언트일 수 있습니다. 설정하고 다시 시도하세요:
                      export STRINGSMITH_GOOGLE_CLIENT_SECRET=…
                """)
        default:
            let detail = parsed?.errorDescription.map { ": \($0)" } ?? ""
            return tr(
                "Google rejected the request (\(code))\(detail)",
                "Google 이 요청을 거부했습니다 (\(code))\(detail)")
        }
    }
}
