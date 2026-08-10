import Foundation
import Testing

@testable import StringsmithCore

// MARK: - V3 키 이름

@Suite("V3 키 이름")
struct KeyRuleTests {

    func entries(_ keys: [String]) -> [LocalizationEntry] {
        keys.enumerated().map {
            LocalizationEntry(key: $1, values: ["ko": "값"], sourceRow: $0 + 2)
        }
    }

    /// 공백은 복사하다 딸려 오고, 눈으로는 보이지 않는다.
    @Test("공백과 잘못된 점을 잡는다")
    func catchesMalformedKeys() {
        let warnings = SheetRules.keyProblems(
            entries(["home title", ".leading", "trailing.", "a..b", "fine.key"]),
            pattern: nil)

        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .key)
        #expect(warnings[0].items.map(\.key) == ["home title", ".leading", "trailing.", "a..b"])
    }

    /// 팀마다 `screen.key` 도 쓰고 `screenKey` 도 쓴다. 기본으로 강요하지 않는다.
    @Test("명명 스타일은 기본으로 따지지 않는다")
    func doesNotImposeAStyle() {
        let mixed = entries(["Screen.CamelCase", "snake_case", "flat", "a.b.c"])
        #expect(SheetRules.keyProblems(mixed, pattern: nil).isEmpty)
    }

    @Test("패턴을 주면 그것만 통과시킨다")
    func enforcesAPatternWhenGiven() {
        let warnings = SheetRules.keyProblems(
            entries(["good.key", "Screen.Bad"]),
            pattern: #"^[a-z0-9]+(\.[a-z0-9_]+)*$"#)

        #expect(warnings.count == 1)
        #expect(warnings[0].items.map(\.key) == ["Screen.Bad"])
    }

    /// 형식이 깨진 키는 어차피 걸린다. 패턴 위반으로 두 번 세지 않는다.
    @Test("형식이 깨진 키를 패턴 위반으로 또 세지 않는다")
    func doesNotDoubleCount() {
        let warnings = SheetRules.keyProblems(
            entries(["has space"]), pattern: #"^[a-z.]+$"#)
        #expect(warnings.count == 1)
        #expect(warnings[0].summary.contains("spaces"))
    }

    @Test("잘못된 정규식은 무시한다")
    func ignoresABrokenPattern() {
        // 설정 오타 하나로 시트 전체를 실패시키지 않는다.
        #expect(SheetRules.keyProblems(entries(["a.b"]), pattern: "[[[").isEmpty)
    }
}

// MARK: - V8 눈에 안 보이는 문자

@Suite("V8 비가시 문자")
struct InvisibleCharacterTests {

    func entry(_ key: String, _ values: [String: String]) -> LocalizationEntry {
        LocalizationEntry(key: key, values: values, sourceRow: 2)
    }

    @Test("붙여넣다 딸려 온 문자를 잡는다")
    func catchesPastedInvisibles() {
        let warnings = SheetRules.invisibleCharacters([
            entry("nbsp", ["ko": "값\u{00A0}입니다"]),
            entry("zwsp", ["ko": "값\u{200B}입니다"]),
            entry("bom", ["ko": "\u{FEFF}값"]),
            entry("clean", ["ko": "값"]),
        ])

        let hidden = try? #require(warnings.first { $0.summary.contains("invisible") })
        // 시트에 나온 순서를 지킨다 — 행을 따라 내려가며 고칠 수 있어야 한다.
        #expect(hidden?.items.map(\.key) == ["nbsp", "zwsp", "bom"])
        #expect(hidden?.kind == .whitespace)
    }

    /// 👨‍👩‍👧‍👦 는 폭 0 접합자로 이어져 있다. 넣으면 멀쩡한 값이 무더기로 걸린다.
    @Test("결합 이모지는 걸리지 않는다")
    func leavesEmojiAlone() {
        let warnings = SheetRules.invisibleCharacters([
            entry("family", ["ko": "가족 👨‍👩‍👧‍👦"])
        ])
        #expect(warnings.isEmpty)
    }

    /// 방향 표시 문자는 아랍어와 라틴 문자를 섞을 때 실제로 필요하다.
    @Test("방향 표시 문자는 걸리지 않는다")
    func leavesDirectionMarksAlone() {
        let warnings = SheetRules.invisibleCharacters([
            entry("rtl", ["ko": "언어: \u{200E}العربية\u{200F}"])
        ])
        #expect(warnings.isEmpty)
    }

    /// 값은 지우지 않기로 했으니(의도일 수 있다) 짚어만 준다.
    @Test("앞뒤 공백은 따로 알려 준다")
    func reportsPaddingSeparately() {
        let warnings = SheetRules.invisibleCharacters([
            entry("padded", ["ko": " 앞뒤 ", "en": "clean"])
        ])

        let padding = try? #require(warnings.first { $0.summary.contains("trailing") })
        #expect(padding?.items.count == 1)
        #expect(padding?.items.first?.note == "ko")
    }
}

// MARK: - V7 길이

@Suite("V7 길이 이상치")
struct LengthRuleTests {

    /// 한국어 → 영어는 원래 글자 수가 배로 는다. 고정 배수를 쓰면 영어 열 전체가 걸린다.
    func table(_ pairs: [(String, String, String)]) -> LocalizationTable {
        LocalizationTable(
            sourceLocale: "ko",
            entries: pairs.enumerated().map { index, pair in
                LocalizationEntry(
                    key: pair.0, values: ["ko": pair.1, "en": pair.2], sourceRow: index + 2)
            })
    }

    /// 원문 8자, 번역 16자 — 비율 2.0 이 열두 개. 여기서 하나만 확 길다.
    func evenTable(extra: String) -> LocalizationTable {
        var rows = (1...12).map { ("k\($0)", "여덟글자짜리원문입니다", "sixteen characters here ok") }
        rows.append(("outlier", "여덟글자짜리원문입니다", String(repeating: "x", count: 200)))
        return table(rows)
    }

    @Test("한 언어 안에서 유독 튀는 것만 잡는다")
    func flagsOnlyTheOutlier() {
        let warnings = SheetRules.lengthOutliers(evenTable(extra: ""), factor: 1.8)

        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .length)
        #expect(warnings[0].items.map(\.key) == ["outlier"])
    }

    /// 언어가 통째로 길어도, 그 언어 안에서 고르면 아무것도 걸리지 않아야 한다.
    @Test("언어 전체가 길어도 고르면 잡지 않는다")
    func toleratesAUniformlyLongerLanguage() {
        let rows = (1...12).map { ("k\($0)", "짧은원문입니다여덟", String(repeating: "y", count: 60)) }
        #expect(SheetRules.lengthOutliers(table(rows), factor: 1.8).isEmpty)
    }

    @Test("0 이면 아예 보지 않는다")
    func canBeTurnedOff() {
        #expect(SheetRules.lengthOutliers(evenTable(extra: ""), factor: 0).isEmpty)
    }

    /// 표본이 적으면 중앙값을 믿을 수 없다.
    @Test("항목이 적으면 판단하지 않는다")
    func staysQuietOnSmallSheets() {
        let rows = (1...5).map { ("k\($0)", "여덟글자짜리원문입니다", String(repeating: "z", count: 200)) }
        #expect(SheetRules.lengthOutliers(table(rows), factor: 1.8).isEmpty)
    }

    /// "네" → "Yes" 만 해도 1.5배다. 짧은 문구는 비율이 의미가 없다.
    @Test("짧은 원문은 세지 않는다")
    func ignoresShortSources() {
        var rows = (1...12).map { ("k\($0)", "여덟글자짜리원문입니다", "sixteen characters here ok") }
        rows.append(("tiny", "네", "Yes indeed absolutely"))
        let warnings = SheetRules.lengthOutliers(table(rows), factor: 1.8)
        #expect(warnings.flatMap { $0.items }.map(\.key).contains("tiny") == false)
    }
}
