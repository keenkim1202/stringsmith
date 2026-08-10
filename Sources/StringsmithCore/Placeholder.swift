import Foundation

// MARK: - 중간표현 (IR)

/// 문자열 안의 변수 자리.
///
/// **타입은 항상 String(`%@`)이다.** 시트에서 타입을 알 방법이 마땅치 않고,
/// 틀린 타입은 런타임에 조용히 값을 깨뜨리는 반면 `%@`는 어떤 값이든 받는다.
public struct Placeholder: Sendable, Equatable {
    /// 이름. `{count}` → `"count"`. 이름 없는 지정자(`%@`)는 `nil`.
    public var name: String?
    /// 시트에 이미 위치 번호가 있었으면 그 값. `%2$@` → `2`.
    public var explicitPosition: Int?
    /// 값 안에서 발견된 순서 (0-based). 이름 없는 지정자를 구분하는 데 쓴다.
    public var ordinal: Int

    /// 로케일 간 대응을 잡는 키.
    ///
    /// 이름이 있으면 이름으로 대응한다 — 그래서 번역의 어순이 달라도 따라갈 수 있다.
    /// 이름이 없으면 순서로만 대응하므로 어순이 바뀌면 알 수 없다(`V1c` 경고).
    public var identity: String {
        if let name { return name }
        if let explicitPosition { return "$\(explicitPosition)" }
        return "#\(ordinal)"
    }
}

/// 파싱된 값. 텍스트와 변수 자리가 번갈아 나온다.
public enum Segment: Sendable, Equatable {
    case text(String)
    case placeholder(Placeholder)
}

public struct ParsedValue: Sendable, Equatable {
    public var segments: [Segment]

    public var placeholders: [Placeholder] {
        segments.compactMap { if case let .placeholder(p) = $0 { return p } else { return nil } }
    }
}

// MARK: - 설정

public struct PlaceholderConfig: Codable, Sendable, Equatable {
    /// 인식할 표기. 레거시 `%@` 행과 신규 `{name}` 행이 한 시트에 섞이는 게 현실이므로 배열이다.
    public var syntax: [String]
    public var braceOpen: String
    public var braceClose: String
    /// 이스케이프 문자. `\{` → 리터럴 `{`, `\\` → 리터럴 `\`.
    ///
    /// 중괄호는 몇 겹이든 **안쪽 쌍이 변수**가 되므로, 겹침 자체는 모호하지 않다.
    /// 리터럴 중괄호가 필요한 자리에만 이 문자를 쓴다.
    public var escape: String
    /// `auto`: 변수가 2개 이상일 때만 위치 지정자(`%1$@`)를 쓴다.
    /// `always`: 항상. `never`: 절대 안 씀(어순이 바뀌는 언어에서 위험).
    public var positional: String
    /// 정수(`%d`)로 내보낼 변수 이름.
    ///
    /// 보통은 비어 있다 — 타입을 항상 `%@` 로 두는 게 이 도구의 결정이다. 예외는 복수형인데,
    /// `.stringsdict` 의 `NSStringPluralRuleType` 은 **수를 봐야** 어느 범주인지 고를 수 있어서
    /// 세는 변수만은 정수여야 한다.
    public var numeric: Set<String>

    public init(
        syntax: [String] = ["apple", "brace"],
        braceOpen: String = "{",
        braceClose: String = "}",
        escape: String = "\\",
        positional: String = "auto",
        numeric: Set<String> = []
    ) {
        self.numeric = numeric
        self.syntax = syntax
        self.braceOpen = braceOpen
        self.braceClose = braceClose
        self.escape = escape
        self.positional = positional
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syntax = try c.decodeIfPresent([String].self, forKey: .syntax) ?? ["apple", "brace"]
        braceOpen = try c.decodeIfPresent(String.self, forKey: .braceOpen) ?? "{"
        braceClose = try c.decodeIfPresent(String.self, forKey: .braceClose) ?? "}"
        escape = try c.decodeIfPresent(String.self, forKey: .escape) ?? "\\"
        positional = try c.decodeIfPresent(String.self, forKey: .positional) ?? "auto"
        numeric = Set(try c.decodeIfPresent([String].self, forKey: .numeric) ?? [])
    }

    var wantsApple: Bool { syntax.contains("apple") }
    var wantsBrace: Bool { syntax.contains("brace") }
    var wantsXML: Bool { syntax.contains("xml") }
}

// MARK: - 파서

/// 여러 표기를 한 번의 스캔으로 처리한다.
///
/// 표기별로 따로 훑으면 앞선 파서가 만든 결과를 뒤 파서가 다시 건드리는 사고가 난다.
/// 한 문자씩 보면서 각 표기에 "여기서 시작하느냐"를 묻고, 먼저 맞는 것이 이긴다.
public struct PlaceholderParser: Sendable {
    public let config: PlaceholderConfig

    public init(config: PlaceholderConfig = PlaceholderConfig()) {
        self.config = config
    }

    /// 실제 제어 문자로 바꿔주는 이스케이프.
    ///
    /// 시트에서 줄바꿈은 셀 안에 진짜 개행을 넣기보다 `\n`으로 적는 경우가 많다.
    /// `.xcstrings`는 JSON이라 이 두 글자를 그대로 두면 앱 화면에 `\n`이 보인다.
    ///
    /// 대가: 리터럴 `\n`(백슬래시와 n)을 표현할 수 없다. iOS 사용자 노출 문구에
    /// 그런 텍스트가 올 일이 없어 받아들인 트레이드오프다.
    static let controlEscapes: [Character: Character] = ["n": "\n", "t": "\t"]

    /// 변환할 수 없는 표기를 함께 돌려준다 (인라인 마크업 등).
    public struct Findings: Sendable, Equatable {
        /// 인라인 마크업 등 변수로 볼 수 없는 표기.
        public var unsupported: [String] = []
    }

    public func parse(_ value: String) -> (ParsedValue, Findings) {
        let chars = Array(value)
        var segments: [Segment] = []
        var text = ""
        var findings = Findings()
        var ordinal = 0
        var i = 0

        func flushText() {
            if !text.isEmpty {
                segments.append(.text(text))
                text = ""
            }
        }

        /// `chars[index]`부터 `token`과 일치하는지.
        func matchesToken(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard !t.isEmpty, index >= 0, index + t.count <= chars.count else { return false }
            return Array(chars[index..<(index + t.count)]) == t
        }

        while i < chars.count {
            // 이스케이프를 가장 먼저 본다.
            //
            // 백슬래시는 **여는 중괄호 바로 앞에서만** 특별하다. 그 자리의 백슬래시 하나가
            // 소모되면서 중괄호를 리터럴로 만든다. 그 외의 모든 자리에서 백슬래시는 그냥 문자다.
            //
            // 이 규칙 덕분에:
            //   \{count}   → {count}      (중괄호 하나 이스케이프)
            //   \\{count}  → \{count}     (앞 백슬래시는 평범한 문자, 뒤 백슬래시가 중괄호를 막음)
            //   C:\path    → C:\path      (시트에 흔한 경로가 깨지지 않음)
            //   \}         → \}           (닫는 중괄호에는 이스케이프가 없음)
            //
            // 대가: "리터럴 백슬래시 + 변수"를 표현할 방법이 없다. 사용자 노출 문구에서
            // 백슬래시 바로 뒤에 변수가 오는 경우가 없어 받아들인 트레이드오프다.
            if !config.escape.isEmpty, matchesToken(config.escape, at: i) {
                let after = i + config.escape.count
                if matchesToken(config.braceOpen, at: after) {
                    text += config.braceOpen
                    i = after + config.braceOpen.count
                    continue
                }
                // 제어 문자 이스케이프. 시트 작성자는 줄바꿈을 `\n`으로 적는다.
                // 그대로 두면 앱에 백슬래시와 n 두 글자가 보인다.
                if after < chars.count, let control = Self.controlEscapes[chars[after]] {
                    text.append(control)
                    i = after + 1
                    continue
                }
                // 그 외에는 평범한 문자로 떨어진다 (아래 default 로 이어짐)
            }

            if config.wantsApple, chars[i] == "%" {
                if let match = matchAppleSpecifier(chars, from: i) {
                    switch match.kind {
                    case .literalPercent:
                        text.append("%")
                    case let .specifier(position):
                        flushText()
                        segments.append(
                            .placeholder(
                                Placeholder(name: nil, explicitPosition: position, ordinal: ordinal)
                            ))
                        ordinal += 1
                    }
                    i = match.end
                    continue
                }
                // 유효한 지정자가 아니면 리터럴 %다 ("50% 할인" 같은 경우)
                text.append("%")
                i += 1
                continue
            }

            if config.wantsBrace, let match = matchBrace(chars, from: i) {
                switch match.kind {
                case let .named(name):
                    flushText()
                    segments.append(
                        .placeholder(Placeholder(name: name, explicitPosition: nil, ordinal: ordinal)))
                    ordinal += 1
                }
                i = match.end
                continue
            }

            if config.wantsXML, chars[i] == "<", let match = matchXMLTag(chars, from: i) {
                switch match.kind {
                case let .selfClosing(name):
                    flushText()
                    segments.append(
                        .placeholder(Placeholder(name: name, explicitPosition: nil, ordinal: ordinal)))
                    ordinal += 1
                case let .markup(raw):
                    // 인라인 마크업(<b>·<link>)은 변수가 아니다. 건드리지 않고 보고만 한다.
                    text.append(raw)
                    if !findings.unsupported.contains(raw) { findings.unsupported.append(raw) }
                }
                i = match.end
                continue
            }

            text.append(chars[i])
            i += 1
        }

        flushText()
        return (ParsedValue(segments: segments), findings)
    }

    // MARK: Apple 포맷 지정자

    enum AppleMatchKind {
        case literalPercent
        case specifier(position: Int?)
    }

    /// `% [n$] [flags][width][.precision][length] conversion` 을 인식한다.
    func matchAppleSpecifier(_ chars: [Character], from start: Int) -> (kind: AppleMatchKind, end: Int)? {
        var i = start + 1
        guard i < chars.count else { return nil }

        if chars[i] == "%" { return (.literalPercent, i + 1) }

        // 위치 번호 n$
        var position: Int? = nil
        var digits = ""
        var j = i
        while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
        if !digits.isEmpty, j < chars.count, chars[j] == "$" {
            position = Int(digits)
            i = j + 1
        }

        // 플래그·너비·정밀도
        //
        // printf의 space 플래그(`% d`)는 **일부러 제외한다.** 포함하면 "50% off"·"50% 할인"의
        // `% o` 같은 조합이 유효한 지정자로 인식되어 평범한 문장이 변수로 둔갑한다.
        // 로컬라이제이션 문자열에서 space 플래그를 쓰는 경우는 사실상 없다.
        while i < chars.count, "-+#0".contains(chars[i]) { i += 1 }
        while i < chars.count, chars[i].isNumber { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        // 길이 수식어
        for modifier in ["hh", "ll", "h", "l", "q", "L", "z", "t", "j"] {
            let m = Array(modifier)
            if i + m.count <= chars.count, Array(chars[i..<(i + m.count)]) == m {
                i += m.count
                break
            }
        }

        // 8진수(o·O)·포인터(p)·16진 부동소수(a·A)는 인식하지 않는다.
        // 사용자 노출 문자열에 쓰일 일이 없는 반면 "50%off" 같은 평범한 텍스트를 오인할 위험만 크다.
        guard i < chars.count, "@dDuUxXfFeEgGcCsS".contains(chars[i]) else { return nil }
        return (.specifier(position: position), i + 1)
    }

    // MARK: 중괄호 표기

    enum BraceMatchKind {
        case named(String)
    }

    /// `{ident}` 하나를 인식한다.
    ///
    /// 이름은 식별자 문자만 허용하므로 `{{count}}`의 바깥 `{`는 뒤에 `{`가 와서 매치되지 않고,
    /// 안쪽 `{count}`만 변수가 된다. **겹친 중괄호는 자연히 안쪽이 이긴다.**
    /// 리터럴 중괄호는 이스케이프(`\{`)로 표현하므로 여기서 따로 다루지 않는다.
    func matchBrace(_ chars: [Character], from start: Int) -> (kind: BraceMatchKind, end: Int)? {
        let open = Array(config.braceOpen)
        let close = Array(config.braceClose)
        guard !open.isEmpty, !close.isEmpty else { return nil }

        func matches(_ token: [Character], at index: Int) -> Bool {
            index + token.count <= chars.count && Array(chars[index..<(index + token.count)]) == token
        }

        guard matches(open, at: start) else { return nil }

        var i = start + open.count
        var name = ""
        while i < chars.count, !matches(close, at: i) {
            let ch = chars[i]
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "." else { return nil }
            name.append(ch)
            i += 1
        }
        guard i < chars.count, !name.isEmpty else { return nil }
        return (.named(name), i + close.count)
    }

    // MARK: XML 표기

    enum XMLMatchKind {
        /// `<count/>` — 변수로 취급한다.
        case selfClosing(String)
        /// `<b>`·`</b>` — 인라인 마크업. 변수가 아니므로 그대로 둔다.
        case markup(String)
    }

    func matchXMLTag(_ chars: [Character], from start: Int) -> (kind: XMLMatchKind, end: Int)? {
        var i = start + 1
        guard i < chars.count else { return nil }

        let isClosing = chars[i] == "/"
        if isClosing { i += 1 }

        var name = ""
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == ":" {
            name.append(chars[i])
            i += 1
        }
        guard !name.isEmpty else { return nil }

        // 속성은 건너뛴다 (<g id="count"> 같은 형태)
        while i < chars.count, chars[i] != ">" { i += 1 }
        guard i < chars.count else { return nil }

        let raw = String(chars[start...i])
        let selfClosing = !isClosing && chars[i - 1] == "/"
        return (selfClosing ? .selfClosing(name) : .markup(raw), i + 1)
    }
}

// MARK: - iOS 포맷 렌더러

/// 원문이 정한 위치 번호에 맞춰 iOS 포맷 문자열을 만든다.
public struct IOSFormatRenderer: Sendable {
    public let config: PlaceholderConfig

    public init(config: PlaceholderConfig = PlaceholderConfig()) {
        self.config = config
    }

    /// 원문이 정한 번호 배정과 표기 방식.
    public struct PositionPlan: Sendable, Equatable {
        /// identity → 위치 번호(1-based).
        public var positions: [String: Int]
        /// `%1$@` 형태를 쓸지. 원문 기준으로 한 번 정해 모든 로케일에 같게 적용한다.
        public var usesPositional: Bool
    }

    /// **원문 값이 번호를 정한다.**
    ///
    /// 처음 나온 순서로 1, 2, 3… 을 부여한다. 시트에 이미 `%2$@`처럼 번호가 있으면 그 값을 존중한다.
    /// 번역은 이 표를 보고 자기 어순대로 렌더링되므로, 번역가는 순서를 신경 쓸 필요가 없다.
    public func plan(for parsed: ParsedValue) -> PositionPlan {
        var map: [String: Int] = [:]
        var next = 1
        var used = Set(parsed.placeholders.compactMap(\.explicitPosition))

        for placeholder in parsed.placeholders {
            let id = placeholder.identity
            if map[id] != nil { continue }
            if let explicit = placeholder.explicitPosition {
                map[id] = explicit
            } else {
                while used.contains(next) { next += 1 }
                map[id] = next
                used.insert(next)
                next += 1
            }
        }
        return PositionPlan(positions: map, usesPositional: wantsPositional(for: parsed))
    }

    /// 위치 지정자를 쓸지 결정한다.
    ///
    /// `auto` 는 **변수가 두 번 이상 등장하면** 켠다. 서로 다른 변수가 둘인 경우뿐 아니라
    /// **같은 변수를 두 번 쓴 경우**(`{name}님, 안녕하세요 {name}님`)도 포함해야 한다.
    /// 후자에서 `%@` 를 쓰면 인자가 둘로 늘어나 같은 값을 두 번 넘겨야 하고,
    /// 다른 값을 넘기면 조용히 어긋난다. `%1$@ … %1$@` 이면 인자 하나로 재사용된다.
    func wantsPositional(for parsed: ParsedValue) -> Bool {
        switch config.positional {
        case "always": return true
        case "never": return false
        default: return parsed.placeholders.count >= 2
        }
    }

    /// - Returns: 렌더링된 문자열. 대응되지 않는 이름이 있으면 `nil`.
    public func render(_ parsed: ParsedValue, using plan: PositionPlan) -> String? {
        let hasPlaceholders = !parsed.placeholders.isEmpty
        var out = ""

        for segment in parsed.segments {
            switch segment {
            case let .text(text):
                // 변수가 있는 문자열은 포맷 문자열로 해석되므로 리터럴 %를 이스케이프한다.
                // 변수가 없으면 포맷 처리되지 않으므로 그대로 둔다.
                out += hasPlaceholders ? text.replacingOccurrences(of: "%", with: "%%") : text
            case let .placeholder(placeholder):
                guard let position = plan.positions[placeholder.identity] else { return nil }
                let type = placeholder.name.map { config.numeric.contains($0) } == true ? "d" : "@"
                out += plan.usesPositional ? "%\(position)$\(type)" : "%\(type)"
            }
        }
        return out
    }
}
