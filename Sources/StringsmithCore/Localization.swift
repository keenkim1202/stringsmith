import Foundation

/// 사용자에게 보이는 문구를 시스템 언어로 고른다.
///
/// - Note: `.lproj` 리소스를 쓰지 않는 이유가 있다. CLI 는 **바이너리 하나로 배포**되는데,
///   SPM 이 만드는 `Bundle.module` 은 실행 파일 옆에 `.bundle` 이 있어야 한다.
///   `/usr/local/bin/stringsmith` 처럼 바이너리만 옮기면 리소스를 찾지 못한다.
///   문구를 코드에 담으면 어디로 옮겨도 동작한다.
///   (창이 있는 미리보기 앱은 `.app` 번들 안에 리소스가 함께 있으므로 그쪽은 `.lproj` 를 쓴다.)
///
/// 지원 언어는 영어·한국어 둘이다. 그 외 언어는 영어로 떨어진다.
public enum Messages {
    public enum Language: String, Sendable {
        case en, ko
    }

    /// 언어를 강제로 지정하는 환경변수. 시스템 설정보다 우선한다.
    ///
    /// 시스템 언어를 바꾸지 않고 다른 언어 출력을 확인할 수 있어야 한다 — CI 와 디버깅에 쓴다.
    public static let overrideKey = "STRINGSMITH_LANG"

    /// 고른 언어. 처음 접근할 때 한 번만 계산한다.
    public static let language: Language = resolve(
        Locale.preferredLanguages,
        override: ProcessInfo.processInfo.environment[overrideKey]
    )

    /// - Parameters:
    ///   - preferred: BCP-47 코드 목록. 앞에 있는 것이 우선순위가 높다.
    ///   - override: 환경변수로 넘어온 강제 지정. 해석되지 않으면 무시한다.
    static func resolve(_ preferred: [String], override: String? = nil) -> Language {
        if let override, let forced = Language(rawValue: override.lowercased()) {
            return forced
        }
        for code in preferred {
            let lower = code.lowercased()
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// 영어·한국어 문구를 함께 적는다.
///
/// 키 테이블 대신 호출 지점에 두 문구를 나란히 둔다. 문구가 40여 개뿐이고,
/// 번역이 코드 옆에 있으면 한쪽만 고치는 사고가 줄어든다.
public func tr(_ en: @autoclosure () -> String, _ ko: @autoclosure () -> String) -> String {
    switch Messages.language {
    case .ko: return ko()
    case .en: return en()
    }
}
