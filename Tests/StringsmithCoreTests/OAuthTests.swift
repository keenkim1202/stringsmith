import Foundation
import Testing

@testable import StringsmithCore

// MARK: - PKCE

@Suite("PKCE")
struct PKCETests {

    /// RFC 7636 부록 B 의 검증 벡터. 우리 구현이 아니라 명세와 맞는지 본다.
    @Test("RFC 7636 의 예시 verifier 는 명세가 적어 둔 challenge 를 낸다")
    func matchesSpecificationVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("verifier 는 매번 다르고 URL 안전 문자만 쓴다")
    func generatesUniqueURLSafeVerifiers() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let verifiers = (0..<50).map { _ in PKCE().verifier }

        #expect(Set(verifiers).count == 50)
        for verifier in verifiers {
            // RFC 7636 은 43~128자를 요구한다.
            #expect(verifier.count >= 43 && verifier.count <= 128)
            #expect(Set(verifier).isSubset(of: allowed))
        }
    }
}

// MARK: - 토큰

@Suite("OAuth 토큰")
struct OAuthTokenTests {

    @Test("만료 60초 전부터 만료로 친다")
    func treatsNearExpiryAsExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func tokens(expiringIn seconds: TimeInterval) -> OAuthTokens {
            OAuthTokens(
                accessToken: "a", refreshToken: "r",
                expiresAt: now.addingTimeInterval(seconds))
        }

        #expect(tokens(expiringIn: 3600).isExpired(at: now) == false)
        #expect(tokens(expiringIn: 61).isExpired(at: now) == false)
        // 요청이 날아가는 동안 만료되는 걸 막으려 여유를 둔다.
        #expect(tokens(expiringIn: 59).isExpired(at: now))
        #expect(tokens(expiringIn: -1).isExpired(at: now))
    }

    @Test("파일 저장소는 왕복하고 권한을 600 으로 좁힌다")
    func fileStoreRoundTripsWithTightPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("credentials.json").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileTokenStore(path: path)
        #expect(try store.load() == nil)

        let saved = OAuthTokens(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000))
        try store.save(saved)

        let loaded = try store.load()
        #expect(loaded?.accessToken == "access")
        #expect(loaded?.refreshToken == "refresh")

        // 토큰 파일을 남이 읽을 수 있으면 안 된다.
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        #expect((mode as? NSNumber)?.int16Value == 0o600)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("깨진 자격증명 파일은 로그인 안 된 상태로 읽는다")
    func treatsCorruptFileAsSignedOut() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))

        // 다시 로그인하면 덮어쓰면 되는 상황이므로 실패시키지 않는다.
        #expect(try FileTokenStore(path: path).load() == nil)
    }
}

// MARK: - 인가 URL

@Suite("OAuth 인가 URL")
struct AuthorizationURLTests {

    func query(_ url: URL?) -> [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("PKCE·state·offline 접근을 모두 싣는다")
    func carriesEverythingGoogleNeeds() {
        let oauth = GoogleOAuth(clientID: "abc.apps.googleusercontent.com", clientSecret: nil)
        let url = oauth.authorizationURL(
            redirectURI: "http://127.0.0.1:51234", challenge: "CHAL", state: "STATE")
        let parameters = query(url)

        #expect(parameters["client_id"] == "abc.apps.googleusercontent.com")
        #expect(parameters["redirect_uri"] == "http://127.0.0.1:51234")
        #expect(parameters["response_type"] == "code")
        #expect(parameters["code_challenge"] == "CHAL")
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["state"] == "STATE")
        // 이 둘이 빠지면 refresh token 이 오지 않아 매번 다시 로그인해야 한다.
        #expect(parameters["access_type"] == "offline")
        #expect(parameters["prompt"] == "consent")
    }

    @Test("읽기 범위 하나만 요구한다")
    func asksForReadOnlySheetsOnly() {
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil)
        let url = oauth.authorizationURL(redirectURI: "http://127.0.0.1:1", challenge: "c", state: "s")

        let scope = query(url)["scope"]
        #expect(scope == "https://www.googleapis.com/auth/spreadsheets.readonly")
        // Drive 범위는 Google 의 "제한" 등급이라 보안 심사가 붙는다. 절대 섞이면 안 된다.
        #expect(scope?.contains("drive") == false)
    }
}

// MARK: - 토큰 교환

@Suite("OAuth 토큰 교환")
struct TokenExchangeTests {

    func response(_ status: Int, _ json: String) -> SheetResponse {
        SheetResponse(status: status, mimeType: "application/json", body: Data(json.utf8))
    }

    @Test("코드를 토큰으로 바꾸고 만료 시각을 계산한다")
    func exchangesCodeForTokens() throws {
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            self.response(200, #"{"access_token":"AT","refresh_token":"RT","expires_in":3599}"#)
        }

        let before = Date()
        let tokens = try oauth.exchange(
            code: "CODE", verifier: "VERIFIER", redirectURI: "http://127.0.0.1:1")

        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.expiresAt.timeIntervalSince(before) >= 3598)
    }

    @Test("비밀값이 없으면 요청에 client_secret 을 넣지 않는다")
    func omitsSecretWhenThereIsNone() throws {
        let seen = Captured()
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { request in
            seen.body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return self.response(200, #"{"access_token":"AT","refresh_token":"RT","expires_in":10}"#)
        }
        _ = try oauth.exchange(code: "CODE", verifier: "V", redirectURI: "http://127.0.0.1:1")

        #expect(seen.body?.contains("client_secret") == false)
        // PKCE 로 대신 증명한다.
        #expect(seen.body?.contains("code_verifier=V") == true)
    }

    @Test("비밀값이 있으면 함께 보낸다")
    func sendsSecretWhenConfigured() throws {
        let seen = Captured()
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: "shh") { request in
            seen.body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return self.response(200, #"{"access_token":"AT","refresh_token":"RT","expires_in":10}"#)
        }
        _ = try oauth.exchange(code: "CODE", verifier: "V", redirectURI: "http://127.0.0.1:1")

        #expect(seen.body?.contains("client_secret=shh") == true)
    }

    /// refresh token 없이 저장하면 다음 실행에서 조용히 재로그인을 요구하게 된다.
    @Test("refresh token 이 없으면 저장하지 않고 실패한다")
    func rejectsAResponseWithoutARefreshToken() {
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            self.response(200, #"{"access_token":"AT","expires_in":3599}"#)
        }
        #expect(throws: StringsmithError.self) {
            try oauth.exchange(code: "C", verifier: "V", redirectURI: "http://127.0.0.1:1")
        }
    }

    @Test("갱신 응답에 refresh token 이 없으면 갖고 있던 것을 유지한다")
    func keepsTheExistingRefreshToken() throws {
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            self.response(200, #"{"access_token":"NEW","expires_in":3599}"#)
        }
        let old = OAuthTokens(accessToken: "OLD", refreshToken: "KEEP", expiresAt: .distantPast)

        let renewed = try oauth.refresh(old)
        #expect(renewed.accessToken == "NEW")
        #expect(renewed.refreshToken == "KEEP")
    }

    @Test("만료된 토큰은 자동으로 갱신되어 저장된다")
    func refreshesAndPersistsExpiredTokens() throws {
        let store = InMemoryTokenStore(
            tokens: OAuthTokens(accessToken: "OLD", refreshToken: "RT", expiresAt: .distantPast))
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            self.response(200, #"{"access_token":"NEW","expires_in":3599}"#)
        }

        #expect(try oauth.validAccessToken(store: store) == "NEW")
        // 갱신 결과를 저장하지 않으면 매 실행마다 갱신 요청이 한 번씩 더 나간다.
        #expect(try store.load()?.accessToken == "NEW")
    }

    @Test("아직 유효한 토큰은 네트워크를 건드리지 않는다")
    func usesAValidTokenWithoutCallingGoogle() throws {
        let store = InMemoryTokenStore(
            tokens: OAuthTokens(
                accessToken: "GOOD", refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600)))
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            Issue.record("유효한 토큰인데 갱신 요청이 나갔습니다")
            return self.response(500, "{}")
        }

        #expect(try oauth.validAccessToken(store: store) == "GOOD")
    }

    @Test("로그인되어 있지 않으면 로그인하라고 안내한다")
    func tellsYouToSignIn() {
        let oauth = GoogleOAuth(clientID: "abc", clientSecret: nil) { _ in
            self.response(200, "{}")
        }
        #expect(throws: StringsmithError.self) {
            try oauth.validAccessToken(store: InMemoryTokenStore())
        }
    }
}

// MARK: - 오류 안내

@Suite("OAuth 오류 안내")
struct OAuthErrorTests {

    func response(_ json: String) -> SheetResponse {
        SheetResponse(status: 400, mimeType: "application/json", body: Data(json.utf8))
    }

    @Test("invalid_grant 는 다시 로그인하라고 알려 준다")
    func explainsAnExpiredGrant() {
        let text = GoogleOAuth.explain(response(#"{"error":"invalid_grant"}"#))
        #expect(text.contains("ss auth login"))
    }

    /// 비밀값 없이 되는지가 이 프로젝트의 열린 질문이라, 거부되면 무엇을 해야 하는지 나와야 한다.
    @Test("invalid_client 는 비밀값 설정 방법을 알려 준다")
    func explainsAClientRejection() {
        let text = GoogleOAuth.explain(response(#"{"error":"invalid_client"}"#))
        #expect(text.contains("STRINGSMITH_GOOGLE_CLIENT_SECRET"))
    }

    @Test("모르는 오류는 구글이 준 설명을 그대로 보여 준다")
    func passesThroughUnknownErrors() {
        let text = GoogleOAuth.explain(
            response(#"{"error":"weird","error_description":"something odd"}"#))
        #expect(text.contains("weird"))
        #expect(text.contains("something odd"))
    }
}

// MARK: - 도우미

/// 가짜 fetch 가 본 요청을 꺼내 오기 위한 상자.
final class Captured: @unchecked Sendable {
    var body: String?
}

// MARK: - 실제로 겪은 응답

@Suite("OAuth — 실제 응답 회귀")
struct OAuthRegressionTests {

    /// 2026-08-10 실제 로그인에서 받은 응답. 구글은 비밀값 누락을 invalid_client 가 아니라
    /// invalid_request 로 답하고, 진짜 이유는 error_description 에만 적는다.
    @Test("비밀값 누락은 설정 방법을 안내한다")
    func explainsAMissingClientSecret() {
        let body = #"{"error":"invalid_request","error_description":"client_secret is missing."}"#
        let text = GoogleOAuth.explain(
            SheetResponse(status: 400, mimeType: "application/json", body: Data(body.utf8)))

        #expect(text.contains("STRINGSMITH_GOOGLE_CLIENT_SECRET"))
    }
}
