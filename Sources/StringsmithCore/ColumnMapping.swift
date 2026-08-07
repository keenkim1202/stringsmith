import Foundation

/// 시트 컬럼명 ↔ 도구가 아는 역할의 대응.
///
/// 팀마다 컬럼명이 다르므로 매핑이 필수다. 다만 손으로 쓰게 하면 진입 마찰이
/// 크므로 `MappingInference`가 초안을 만들고 사용자는 확인·수정만 한다.
public struct ColumnMapping: Codable, Sendable, Equatable {
    /// 문자열 키가 들어 있는 컬럼명. 필수.
    public var key: String
    /// 화면·그룹 컬럼명. 네임스페이스·주석에 쓰인다. 선택.
    public var screen: String?
    /// 설명 컬럼명. `.xcstrings` comment로 나간다. 선택.
    public var description: String?
    /// 로케일 코드 → 시트 컬럼명. 최소 1개 필요.
    public var languages: [String: String]

    public init(
        key: String,
        screen: String? = nil,
        description: String? = nil,
        languages: [String: String]
    ) {
        self.key = key
        self.screen = screen
        self.description = description
        self.languages = languages
    }
}

// MARK: - 헤더 추론

/// 시트 헤더를 읽어 매핑 초안을 만든다.
public enum MappingInference {

    /// 추론 결과. 매핑되지 않은 컬럼도 함께 돌려주어 사용자가 확인할 수 있게 한다.
    public struct Result: Sendable, Equatable {
        public var mapping: ColumnMapping?
        /// 어떤 역할에도 매핑되지 않은 컬럼명들.
        public var unmapped: [String]
        /// 매핑을 만들지 못한 이유 (key 컬럼을 못 찾았거나 언어 컬럼이 없을 때).
        public var failureReason: String?
    }

    public static func infer(headers: [String]) -> Result {
        let trimmed = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var claimed = Set<String>()

        func findFirst(in aliases: Set<String>) -> String? {
            for header in trimmed where !claimed.contains(header) {
                if aliases.contains(normalize(header)) {
                    claimed.insert(header)
                    return header
                }
            }
            return nil
        }

        let keyColumn = findFirst(in: keyAliases)
        let screenColumn = findFirst(in: screenAliases)
        let descriptionColumn = findFirst(in: descriptionAliases)

        var languages: [String: String] = [:]
        for header in trimmed where !claimed.contains(header) && !header.isEmpty {
            if let locale = localeCode(for: header) {
                // 같은 로케일에 두 컬럼이 붙으면 먼저 나온 것을 쓴다.
                if languages[locale] == nil {
                    languages[locale] = header
                    claimed.insert(header)
                }
            }
        }

        let unmapped = trimmed.filter { !claimed.contains($0) && !$0.isEmpty }

        guard let keyColumn else {
            return Result(
                mapping: nil,
                unmapped: unmapped,
                failureReason: tr(
                    "No key column found. Nothing named like 'key'.",
                    "키 컬럼을 찾지 못했습니다. 'key' 또는 '키' 같은 이름이 없습니다.")
            )
        }
        guard !languages.isEmpty else {
            return Result(
                mapping: nil,
                unmapped: unmapped,
                failureReason: tr(
                    "No language column found. Nothing named like 'ko', 'en', or 'English'.",
                    "언어 컬럼을 하나도 찾지 못했습니다. '한국어'·'ko'·'English' 같은 이름이 없습니다.")
            )
        }

        return Result(
            mapping: ColumnMapping(
                key: keyColumn,
                screen: screenColumn,
                description: descriptionColumn,
                languages: languages
            ),
            unmapped: unmapped,
            failureReason: nil
        )
    }

    // MARK: 별칭 테이블

    static let keyAliases: Set<String> = [
        "key", "키", "id", "identifier", "stringkey", "stringid", "스트링키", "문자열키", "name",
    ]

    static let screenAliases: Set<String> = [
        "screen", "화면", "page", "페이지", "view", "뷰",
        "section", "섹션", "category", "카테고리", "group", "그룹", "구분", "모듈", "module",
    ]

    static let descriptionAliases: Set<String> = [
        "description", "설명", "comment", "코멘트", "주석",
        "note", "노트", "비고", "memo", "메모", "context", "맥락", "desc",
    ]

    /// 로케일 코드 ← 흔한 컬럼명. 한국 팀 시트에서 실제로 쓰이는 표기를 우선 담았다.
    static let localeAliases: [String: Set<String>] = [
        "ko": ["ko", "kokr", "kr", "한국어", "한글", "korean"],
        "en": ["en", "enus", "engb", "us", "영어", "english"],
        "ja": ["ja", "jajp", "jp", "일본어", "japanese"],
        "zh-Hans": ["zhhans", "zhcn", "cn", "중국어간체", "간체", "중국어간체자", "simplifiedchinese", "chinesesimplified"],
        "zh-Hant": ["zhhant", "zhtw", "tw", "중국어번체", "번체", "traditionalchinese", "chinesetraditional"],
        "es": ["es", "eses", "스페인어", "spanish"],
        "fr": ["fr", "frfr", "프랑스어", "french"],
        "de": ["de", "dede", "독일어", "german"],
        "pt": ["pt", "ptbr", "포르투갈어", "portuguese"],
        "ru": ["ru", "руru", "러시아어", "russian"],
        "ar": ["ar", "아랍어", "arabic"],
        "vi": ["vi", "베트남어", "vietnamese"],
        "th": ["th", "태국어", "thai"],
        "id": ["id", "인도네시아어", "indonesian"],
        "it": ["it", "이탈리아어", "italian"],
        "tr": ["tr", "터키어", "turkish"],
        "hi": ["hi", "힌디어", "hindi"],
    ]

    /// 헤더로 보이는 행을 찾는다. 1-based 행 번호를 돌려준다.
    ///
    /// 실무 시트는 위쪽에 제목·안내·범례 행이 붙어 있는 경우가 흔해서
    /// `--header-row`를 매번 손으로 세는 것이 번거롭다. 알려진 별칭에
    /// 몇 개나 걸리는지로 점수를 매겨 가장 헤더다운 행을 고른다.
    ///
    /// - Parameter maxScan: 위에서부터 검사할 행 수. 그보다 아래에 헤더가 있으면 못 찾는다.
    /// - Returns: 후보를 찾지 못하면 `nil`.
    public static func detectHeaderRow(in rows: [[String]], maxScan: Int = 15) -> Int? {
        var best: (row: Int, score: Int)? = nil

        for (offset, row) in rows.prefix(maxScan).enumerated() {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard cells.count >= 2 else { continue }

            let result = infer(headers: cells)
            guard let mapping = result.mapping else { continue }

            // 키 컬럼 1 + 언어 수 + 선택 컬럼. 매핑이 많이 걸릴수록 헤더일 가능성이 높다.
            var score = 1 + mapping.languages.count
            if mapping.screen != nil { score += 1 }
            if mapping.description != nil { score += 1 }

            if best == nil || score > best!.score {
                best = (offset + 1, score)
            }
        }
        return best?.row
    }

    /// 헤더 하나를 로케일 코드로 해석한다. 못 하면 nil.
    public static func localeCode(for header: String) -> String? {
        let n = normalize(header)
        guard !n.isEmpty else { return nil }
        for (code, aliases) in localeAliases where aliases.contains(n) {
            return code
        }
        return nil
    }

    /// 비교용 정규화: 소문자 + 공백·구분자·괄호 제거.
    ///
    /// "중국어 (간체)" → "중국어간체", "zh-Hans" → "zhhans"
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { ch in
            !ch.isWhitespace && ch != "-" && ch != "_" && ch != "(" && ch != ")" && ch != "."
        }
    }
}

// MARK: - 컬럼 조회와 오탈자 제안

/// 헤더 배열에서 컬럼 인덱스를 찾고, 실패 시 제안을 담은 오류를 던진다.
struct HeaderIndex {
    let headers: [String]
    private let lookup: [String: Int]

    init(headers: [String]) {
        self.headers = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var map: [String: Int] = [:]
        for (i, h) in self.headers.enumerated() where map[h] == nil {
            map[h] = i
        }
        self.lookup = map
    }

    func index(of column: String, role: String) throws -> Int {
        if let i = lookup[column] { return i }
        // 정규화 후 재시도 — 공백·대소문자 차이는 조용히 흡수한다.
        let target = MappingInference.normalize(column)
        if let i = headers.firstIndex(where: { MappingInference.normalize($0) == target }) {
            return i
        }
        throw StringsmithError.columnNotFound(
            requested: column,
            role: role,
            available: headers.filter { !$0.isEmpty },
            suggestion: closestMatch(to: column)
        )
    }

    /// 편집 거리 기반 근접 후보. 임계값을 넘으면 제안하지 않는다.
    func closestMatch(to column: String) -> String? {
        let target = MappingInference.normalize(column)
        var best: (name: String, distance: Int)? = nil
        for h in headers where !h.isEmpty {
            let d = editDistance(target, MappingInference.normalize(h))
            if best == nil || d < best!.distance { best = (h, d) }
        }
        guard let best else { return nil }
        // 짧은 문자열에서 거리 3은 사실상 무관한 단어다.
        let threshold = max(1, min(3, target.count / 2))
        return best.distance <= threshold ? best.name : nil
    }
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}
