import Foundation

/// stringsmith 가 배포하는 Google OAuth 클라이언트.
///
/// 클라이언트 ID 는 비밀이 아니다 — 설치형 앱에서는 어차피 사용자에게 노출되는 값이고,
/// OAuth 명세도 공개를 전제한다. 실제 보호는 각자의 Google 로그인과 PKCE 가 한다.
///
/// 자기 조직의 클라이언트를 쓰고 싶으면 환경 변수로 덮어쓴다. 미검증 앱 경고나 사용자
/// 한도를 피해야 하는 조직을 위한 통로다:
///
///     export STRINGSMITH_GOOGLE_CLIENT_ID=…apps.googleusercontent.com
///     export STRINGSMITH_GOOGLE_CLIENT_SECRET=…   # 그 유형의 클라이언트가 요구할 때만
public enum GoogleClient {
    /// 배포본에 들어가는 기본 클라이언트. 비어 있으면 사용자가 직접 등록해야 한다.
    static let builtInID = ""

    /// 데스크톱 클라이언트는 비밀값을 비밀로 지킬 수 없다. 그래서 이 도구는 **PKCE** 를
    /// 쓰고 비밀값 없이 동작하는 걸 기본으로 삼는다. 비밀값을 요구하는 클라이언트
    /// 유형이라면 환경 변수로 넣는다.
    static let builtInSecret: String? = nil

    public static var id: String {
        let override = ProcessInfo.processInfo.environment["STRINGSMITH_GOOGLE_CLIENT_ID"]
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? builtInID
    }

    public static var secret: String? {
        let override = ProcessInfo.processInfo.environment["STRINGSMITH_GOOGLE_CLIENT_SECRET"]
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? builtInSecret
    }

    public static var isConfigured: Bool { !id.isEmpty }

    /// 시트 읽기 하나만 요구한다.
    ///
    /// 범위를 좁게 두는 건 예의 문제가 아니라 실질적인 차이다. Drive 범위는 Google 의
    /// "제한(restricted)" 등급이라 보안 심사까지 필요하고, 사용자에게도 훨씬 큰 권한을 묻게 된다.
    public static let scope = "https://www.googleapis.com/auth/spreadsheets.readonly"

    /// 클라이언트가 설정되지 않았을 때의 안내.
    public static var notConfiguredMessage: String {
        tr(
            """
            No Google OAuth client is configured in this build.
              → Create a "Desktop app" OAuth client in Google Cloud Console, then:
                  export STRINGSMITH_GOOGLE_CLIENT_ID=…apps.googleusercontent.com
                See the README for the five-minute walkthrough.
            """,
            """
            이 빌드에는 Google OAuth 클라이언트가 설정되어 있지 않습니다.
              → Google Cloud Console 에서 "데스크톱 앱" OAuth 클라이언트를 만든 뒤:
                  export STRINGSMITH_GOOGLE_CLIENT_ID=…apps.googleusercontent.com
                자세한 절차는 README 를 보세요.
            """)
    }
}
