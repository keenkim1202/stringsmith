import Foundation

/// 사용자가 등록한 Google OAuth 클라이언트.
///
/// **이 저장소에는 클라이언트가 들어 있지 않다.** 넣으려면 클라이언트 비밀값을 공개
/// 저장소에 올려야 하는데, 설치형 앱에서는 관례적으로 허용되는 일이라 해도 남의 키를
/// 대신 노출시키는 일이다. 각자 5분이면 발급받을 수 있으므로 그렇게 하지 않기로 했다.
///
/// 찾는 순서는 환경 변수 → 설정 파일이다. 환경 변수는 CI 나 일회성 실행에서 덮어쓰기
/// 좋고, 설정 파일은 셸을 새로 열 때마다 다시 export 하지 않아도 된다.
public enum GoogleClient {

    /// `~/.config/stringsmith/client.json`
    public static var configPath: String {
        homeDirectory() + "/.config/stringsmith/client.json"
    }

    public static var id: String {
        value(environment: "STRINGSMITH_GOOGLE_CLIENT_ID", file: \.clientId) ?? ""
    }

    public static var secret: String? {
        value(environment: "STRINGSMITH_GOOGLE_CLIENT_SECRET", file: \.clientSecret)
    }

    public static var isConfigured: Bool { !id.isEmpty }

    /// 시트 읽기 하나만 요구한다.
    ///
    /// 범위를 좁게 두는 건 예의 문제가 아니라 실질적인 차이다. Drive 범위는 Google 의
    /// "제한(restricted)" 등급이라 보안 심사까지 필요하고, 사용자에게도 훨씬 큰 권한을 묻게 된다.
    public static let scope = "https://www.googleapis.com/auth/spreadsheets.readonly"

    // MARK: 읽기

    static func value(environment key: String, file keyPath: KeyPath<Stored, String?>) -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment[key],
            !fromEnvironment.isEmpty
        {
            return fromEnvironment
        }
        guard let stored = load(), let value = stored[keyPath: keyPath], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Google Cloud Console 이 내려 주는 JSON 을 그대로 받아 준다.
    ///
    /// 콘솔의 다운로드 파일은 `{"installed": {...}}` 로 한 겹 싸여 있다. 그걸 풀어 붙여 넣게
    /// 하는 것보다 그대로 저장하게 하는 편이 실수가 적다. 평평한 형태도 함께 받는다.
    struct Stored: Decodable {
        var clientId: String?
        var clientSecret: String?

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case clientSecret = "client_secret"
            case installed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let nested = try? container.nestedContainer(
                keyedBy: CodingKeys.self, forKey: .installed)
            {
                clientId = try? nested.decode(String.self, forKey: .clientId)
                clientSecret = try? nested.decode(String.self, forKey: .clientSecret)
            } else {
                clientId = try? container.decode(String.self, forKey: .clientId)
                clientSecret = try? container.decode(String.self, forKey: .clientSecret)
            }
        }
    }

    static func load(path: String? = nil) -> Stored? {
        let path = path ?? configPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    // MARK: 안내

    /// 클라이언트가 없을 때 보여 줄 설정 절차.
    ///
    /// 여기가 사실상 유일한 진입점이라 "README 를 보라" 로 끝내지 않는다. 막힌 사람이
    /// 화면을 떠나지 않고 끝낼 수 있어야 한다.
    public static var notConfiguredMessage: String {
        tr(
            """
            No Google OAuth client is set up yet.

            This tool ships without one on purpose: bundling a client would mean publishing
            its secret. Yours takes about five minutes:

              1. console.cloud.google.com → create a project
              2. APIs & Services → Library → enable "Google Sheets API"
              3. OAuth consent screen → External → add the scope
                 .../auth/spreadsheets.readonly → add yourself under Test users
              4. Credentials → Create credentials → OAuth client ID
                 → Application type: Desktop app
              5. Download the JSON and save it as:
                   \(configPath)

            The downloaded file works as-is. Or write it yourself:

              { "client_id": "….apps.googleusercontent.com", "client_secret": "…" }

            Environment variables override the file:
              STRINGSMITH_GOOGLE_CLIENT_ID, STRINGSMITH_GOOGLE_CLIENT_SECRET
            """,
            """
            Google OAuth 클라이언트가 아직 설정되지 않았습니다.

            이 도구는 클라이언트를 내장하지 않습니다. 내장하려면 비밀값을 공개 저장소에
            올려야 하기 때문입니다. 직접 발급받는 데 5분이면 됩니다:

              1. console.cloud.google.com → 프로젝트 만들기
              2. API 및 서비스 → 라이브러리 → "Google Sheets API" 사용 설정
              3. OAuth 동의 화면 → 외부 → 범위에
                 .../auth/spreadsheets.readonly 추가 → 테스트 사용자에 본인 계정 추가
              4. 사용자 인증 정보 → 사용자 인증 정보 만들기 → OAuth 클라이언트 ID
                 → 애플리케이션 유형: 데스크톱 앱
              5. JSON 을 다운로드해 이 경로에 저장:
                   \(configPath)

            다운로드한 파일을 그대로 두면 됩니다. 직접 적어도 됩니다:

              { "client_id": "….apps.googleusercontent.com", "client_secret": "…" }

            환경 변수가 파일보다 우선합니다:
              STRINGSMITH_GOOGLE_CLIENT_ID, STRINGSMITH_GOOGLE_CLIENT_SECRET
            """)
    }
}

/// 홈 디렉터리.
///
/// `FileManager.homeDirectoryForCurrentUser` 는 계정 정보를 보고 `$HOME` 을 무시한다.
/// CLI 는 `$HOME` 을 따르는 게 관례고(gcloud·aws 도 그렇다), 그래야 테스트와 CI 에서
/// 설정을 격리할 수 있다.
func homeDirectory() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return home
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}
