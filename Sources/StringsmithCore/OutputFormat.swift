import Foundation

/// 로컬라이제이션 파일 형식.
///
/// 프로젝트는 둘 중 하나를 쓴다. 같은 문자열을 두 형식으로 동시에 두면 어느 쪽이 실제로
/// 읽히는지 헷갈리고, 한쪽만 갱신됐을 때 알아채기 어렵다. 그래서 **고르는 것**으로 뒀다.
public enum OutputFormat: String, Sendable, CaseIterable {
    /// Xcode String Catalog. 하나의 `.xcstrings` 에 모든 언어가 들어간다.
    case xcstrings
    /// 이전 형식. 언어마다 `.lproj/Localizable.strings` 가 생기고, 복수형은
    /// `.stringsdict` 로 따로 나간다.
    case strings

    /// 이 형식이 만드는 산출물.
    ///
    /// `strings` 를 고르면 `stringsdict` 가 따라온다. 둘은 한 쌍이라 따로 고를 일이 없다 —
    /// 복수형이 없으면 `.stringsdict` 는 애초에 만들어지지 않는다.
    public var artifacts: [String] {
        switch self {
        case .xcstrings: return ["xcstrings"]
        case .strings: return ["strings", "stringsdict"]
        }
    }

    /// 산출물 목록에서 형식을 되읽는다. 설정 파일이 어느 쪽인지 볼 때 쓴다.
    public static func detect(in artifacts: [String]) -> OutputFormat? {
        if artifacts.contains("xcstrings") { return .xcstrings }
        if artifacts.contains("strings") { return .strings }
        return nil
    }

    /// 형식만 바꾸고 나머지는 그대로 둔 산출물 목록.
    ///
    /// `swift` 는 형식과 무관하다 — 어느 쪽을 쓰든 타입 안전 접근자는 필요하다. 설정에서
    /// 켜 뒀으면 유지한다.
    public func applied(to artifacts: [String]) -> [String] {
        var out = self.artifacts
        for extra in artifacts where !OutputFormat.owned.contains(extra) {
            out.append(extra)
        }
        return out
    }

    /// 형식이 결정하는 산출물 이름들.
    static let owned: Set<String> = ["xcstrings", "strings", "stringsdict"]
}
