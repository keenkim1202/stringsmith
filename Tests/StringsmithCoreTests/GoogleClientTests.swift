import Foundation
import Testing

@testable import StringsmithCore

@Suite("OAuth 클라이언트 설정")
struct GoogleClientTests {

    func withFile(_ contents: String, _ body: (String) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        try body(path)
    }

    /// 콘솔에서 받은 파일을 풀어 붙여 넣게 하면 실수가 생긴다. 그대로 저장하면 되게 한다.
    @Test("콘솔이 내려 주는 installed 형태를 그대로 읽는다")
    func readsTheConsoleDownload() throws {
        let downloaded = """
            {"installed":{
              "client_id":"123-abc.apps.googleusercontent.com",
              "project_id":"stringsmith",
              "auth_uri":"https://accounts.google.com/o/oauth2/auth",
              "token_uri":"https://oauth2.googleapis.com/token",
              "client_secret":"GOCSPX-example"
            }}
            """
        try withFile(downloaded) { path in
            let stored = GoogleClient.load(path: path)
            #expect(stored?.clientId == "123-abc.apps.googleusercontent.com")
            #expect(stored?.clientSecret == "GOCSPX-example")
        }
    }

    @Test("직접 적은 평평한 형태도 읽는다")
    func readsAHandWrittenFile() throws {
        let written = #"{"client_id":"abc.apps.googleusercontent.com","client_secret":"s3cret"}"#
        try withFile(written) { path in
            let stored = GoogleClient.load(path: path)
            #expect(stored?.clientId == "abc.apps.googleusercontent.com")
            #expect(stored?.clientSecret == "s3cret")
        }
    }

    @Test("없는 파일과 깨진 파일은 미설정으로 본다")
    func treatsMissingOrBrokenAsUnset() throws {
        #expect(GoogleClient.load(path: "/nonexistent/client.json") == nil)
        try withFile("{ not json") { path in
            #expect(GoogleClient.load(path: path) == nil)
        }
    }

    @Test("아무것도 없는 상태에서는 설정되지 않은 것으로 본다")
    func reportsUnconfiguredWhenEmpty() throws {
        try withFile("{}") { path in
            let stored = GoogleClient.load(path: path)
            #expect(stored?.clientId == nil)
            #expect(stored?.clientSecret == nil)
        }
    }

    /// 여기서 막힌 사람은 다른 문서를 찾아갈 수 없다. 화면 안에서 끝나야 한다.
    @Test("미설정 안내는 발급 절차와 저장 위치를 모두 담는다")
    func explainsHowToSetUp() {
        let message = GoogleClient.notConfiguredMessage

        #expect(message.contains("console.cloud.google.com"))
        #expect(message.contains(GoogleClient.configPath))
        #expect(message.contains("client_secret"))
        #expect(message.contains("STRINGSMITH_GOOGLE_CLIENT_ID"))
    }

    @Test("읽기 범위 하나만 요구한다")
    func asksForOneScope() {
        #expect(GoogleClient.scope == "https://www.googleapis.com/auth/spreadsheets.readonly")
    }
}

// MARK: - 저장소에 들어 있는 예시 파일

@Suite("예시 클라이언트 파일")
struct ExampleClientFileTests {

    /// 예시 파일만 보고 온 사람에게도 저장 위치가 보여야 한다. 설명을 넣은 김에,
    /// 그 설명 때문에 파싱이 깨지지 않는지도 함께 확인한다.
    @Test("설명 필드가 있어도 값을 읽어 낸다")
    func parsesDespiteTheNotes() throws {
        let example = """
            {
              "_where": "Copy this to ~/.config/stringsmith/client.json …",
              "_how": "Google Cloud Console → Credentials → …",
              "client_id": "000000000000-xxxx.apps.googleusercontent.com",
              "client_secret": "your-client-secret-here"
            }
            """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(example.utf8).write(to: URL(fileURLWithPath: path))

        let stored = GoogleClient.load(path: path)
        #expect(stored?.clientId == "000000000000-xxxx.apps.googleusercontent.com")
        #expect(stored?.clientSecret == "your-client-secret-here")
    }
}
