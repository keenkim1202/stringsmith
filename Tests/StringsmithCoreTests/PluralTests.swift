import Foundation
import Testing

@testable import StringsmithCore

// MARK: - CLDR 표

@Suite("CLDR 복수 범주")
struct CLDRTests {

    @Test("언어마다 쓰는 범주가 다르다")
    func knowsCommonLocales() {
        #expect(CLDR.categories(for: "ko") == [.other])
        #expect(CLDR.categories(for: "ja") == [.other])
        #expect(CLDR.categories(for: "en") == [.one, .other])
        #expect(CLDR.categories(for: "ru") == [.one, .few, .many, .other])
        #expect(CLDR.categories(for: "ar")?.count == 6)
    }

    @Test("지역 변형은 기본 언어를 따른다")
    func fallsBackToTheBaseLanguage() {
        #expect(CLDR.categories(for: "en-GB") == CLDR.categories(for: "en"))
        #expect(CLDR.categories(for: "zh-Hant") == [.other])
    }

    /// 틀린 경고를 내는 것보다 조용한 편이 낫다.
    @Test("모르는 언어는 아무 말도 하지 않는다")
    func staysQuietOnUnknownLocales() {
        #expect(CLDR.categories(for: "xx") == nil)
    }

    @Test("범주는 CLDR 순서로 정렬된다")
    func sortsInCLDROrder() {
        #expect(
            [PluralCategory.other, .one, .few].sorted() == [.one, .few, .other])
    }
}

// MARK: - 묶기

@Suite("복수형 묶기")
struct PluralSplitTests {

    func table(_ pairs: [(String, [String: String])]) -> LocalizationTable {
        LocalizationTable(
            sourceLocale: "ko",
            entries: pairs.enumerated().map {
                LocalizationEntry(key: $1.0, values: $1.1, sourceRow: $0 + 2)
            })
    }

    @Test("접미사가 같은 키들을 한 항목으로 묶는다")
    func groupsBySuffix() {
        let (groups, singles) = Plurals.split(
            table([
                ("cart.items.one", ["en": "1 item"]),
                ("cart.items.other", ["ko": "상품", "en": "items"]),
                ("cart.title", ["ko": "장바구니"]),
            ]))

        #expect(groups.count == 1)
        #expect(groups[0].key == "cart.items")
        #expect(groups[0].variants.keys.sorted() == [.one, .other])
        #expect(singles.map(\.key) == ["cart.title"])
    }

    /// `ringtone` 이나 `settings.done` 처럼 우연히 범주 이름으로 끝나는 키가 있다.
    @Test("접미사가 하나뿐이면 묶지 않는다")
    func leavesLoneSuffixesAlone() {
        let (groups, singles) = Plurals.split(
            table([
                ("audio.one", ["ko": "하나"]),
                ("other", ["ko": "그 밖에"]),
            ]))

        #expect(groups.isEmpty)
        #expect(singles.map(\.key).sorted() == ["audio.one", "other"])
    }
}

// MARK: - V6

@Suite("V6 복수형 검증")
struct PluralValidationTests {

    func group(_ key: String, _ variants: [PluralCategory: [String: String]]) -> PluralGroup {
        PluralGroup(
            key: key,
            variants: variants.mapValues {
                LocalizationEntry(key: key, values: $0, sourceRow: 2)
            })
    }

    /// CLDR 은 `other` 를 항상 요구한다. 없으면 iOS 가 보여 줄 게 없다.
    @Test("other 가 없으면 알린다")
    func requiresOther() {
        let warnings = Plurals.problems(
            [group("a", [.one: ["en": "One"], .two: ["en": "Two"]])],
            locales: ["en"], sourceLocale: "ko")

        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .plural)
        #expect(warnings[0].summary.contains("other"))
    }

    @Test("그 언어가 쓰지 않는 범주를 짚는다")
    func flagsUnusedCategories() {
        // 한국어는 `other` 뿐인데 `one` 을 채웠다.
        let warnings = Plurals.problems(
            [group("a", [.one: ["ko": "하나"], .other: ["ko": "여럿"]])],
            locales: ["ko"], sourceLocale: "ko")

        let unused = try? #require(warnings.first { $0.summary.contains("never uses") })
        #expect(unused?.items.first?.note?.contains("one") == true)
    }

    @Test("그 언어에 필요한데 없는 범주를 짚는다")
    func flagsMissingCategories() {
        // 러시아어는 one·few·many·other 를 다 쓴다.
        let warnings = Plurals.problems(
            [group("a", [.one: ["ru": "Один"], .other: ["ru": "Много"]])],
            locales: ["ru"], sourceLocale: "ko")

        let lacking = try? #require(warnings.first { $0.summary.contains("lacks") })
        #expect(lacking?.items.first?.note?.contains("few") == true)
    }

    @Test("맞게 채운 시트는 조용하다")
    func staysQuietWhenCorrect() {
        let warnings = Plurals.problems(
            [
                group(
                    "a",
                    [
                        .one: ["en": "1 item", "ru": "Один"],
                        .few: ["ru": "Два"],
                        .many: ["ru": "Много"],
                        .other: ["ko": "상품", "en": "items", "ru": "Товара"],
                    ])
            ],
            locales: ["ko", "en", "ru"], sourceLocale: "ko")

        #expect(warnings.isEmpty)
    }
}

// MARK: - 산출물

@Suite("레거시 산출물")
struct LegacyOutputTests {

    @Test("strings 는 키 순으로 나온다")
    func stringsAreSorted() {
        let text = LegacyOutput.strings(
            for: "en",
            entries: [
                LocalizationEntry(key: "z.last", values: ["en": "Z"]),
                LocalizationEntry(key: "a.first", values: ["en": "A"]),
            ])
        // 시트 순서를 따라가면 행 하나 옮길 때마다 파일 전체가 diff 에 뜬다.
        #expect(text.range(of: "a.first")!.lowerBound < text.range(of: "z.last")!.lowerBound)
    }

    @Test("문법에서 뜻이 있는 문자를 이스케이프한다")
    func escapesStringsSyntax() {
        let text = LegacyOutput.strings(
            for: "en",
            entries: [
                LocalizationEntry(key: "k", values: ["en": #"say "hi"\ and"# + "\n" + "next"])
            ])
        #expect(text.contains(#"\"hi\""#))
        #expect(text.contains(#"\\"#))
        #expect(text.contains(#"\n"#))
    }

    @Test("번역이 없는 로케일은 건너뛴다")
    func skipsMissingTranslations() {
        let text = LegacyOutput.strings(
            for: "ja",
            entries: [LocalizationEntry(key: "k", values: ["en": "only english"])])
        #expect(text.contains("\"k\"") == false)
    }

    @Test("stringsdict 는 복수 규칙 구조를 갖춘다")
    func writesPluralStructure() throws {
        let group = PluralGroup(
            key: "cart.items",
            variants: [
                .one: LocalizationEntry(key: "cart.items.one", values: ["en": "%d item"]),
                .other: LocalizationEntry(key: "cart.items.other", values: ["en": "%d items"]),
            ])
        let text = try #require(LegacyOutput.stringsdict(for: "en", groups: [group]))

        #expect(text.contains("NSStringPluralRuleType"))
        // 수를 봐야 어느 범주인지 고를 수 있다. 문자열이면 iOS 가 판단할 수 없다.
        #expect(text.contains("<string>d</string>"))
        #expect(text.contains("%#@count@"))
        #expect(text.contains("<string>%d items</string>"))

        // Foundation 이 읽을 수 있는 plist 여야 한다.
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(text.utf8), format: nil) as? [String: Any]
        #expect(parsed?["cart.items"] != nil)
    }

    @Test("XML 에서 뜻이 있는 문자를 이스케이프한다")
    func escapesXML() throws {
        let group = PluralGroup(
            key: "k",
            variants: [
                .one: LocalizationEntry(key: "k.one", values: ["en": "<b>1</b> & more"]),
                .other: LocalizationEntry(key: "k.other", values: ["en": "many"]),
            ])
        let text = try #require(LegacyOutput.stringsdict(for: "en", groups: [group]))

        #expect(text.contains("&lt;b&gt;"))
        #expect(text.contains("&amp;"))
        _ = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
    }

    /// 빈 plist 를 남겨 두면 Xcode 가 경고를 낸다.
    @Test("쓸 것이 없으면 파일을 만들지 않는다")
    func returnsNilWhenEmpty() {
        #expect(LegacyOutput.stringsdict(for: "ja", groups: []) == nil)

        let englishOnly = PluralGroup(
            key: "k",
            variants: [.other: LocalizationEntry(key: "k.other", values: ["en": "x"])])
        #expect(LegacyOutput.stringsdict(for: "ja", groups: [englishOnly]) == nil)
    }
}

// MARK: - 원문이 없는 행

@Suite("원문 없는 행의 변환")
struct SourcelessConversionTests {

    /// 한국어는 `other` 뿐이라 `cart.items.one` 의 한국어 칸이 정상적으로 빈다.
    /// 이때 영어·러시아어 값이 변환되지 않고 `{count}` 그대로 나가던 버그가 있었다.
    @Test("원문이 없어도 번역은 변환된다")
    func convertsWithoutASource() {
        let table = LocalizationTable(
            sourceLocale: "ko",
            entries: [
                LocalizationEntry(
                    key: "cart.items.one", values: ["en": "{count} item"], sourceRow: 3)
            ])
        let result = PlaceholderProcessor(config: PlaceholderConfig()).process(table)

        #expect(result.table.entries[0].values["en"] == "%@ item")
        #expect(result.conversions.count == 1)
    }

    @Test("세는 변수만 정수로 나간다")
    func rendersOnlyTheCountAsInteger() {
        let table = LocalizationTable(
            sourceLocale: "ko",
            entries: [
                LocalizationEntry(
                    key: "k", values: ["ko": "{name}님 {count}개"], sourceRow: 2)
            ])
        let config = PlaceholderConfig(numeric: ["count"])
        let result = PlaceholderProcessor(config: config).process(table)

        // name 은 문자열, count 만 정수.
        #expect(result.table.entries[0].values["ko"] == "%1$@님 %2$d개")
    }
}

// MARK: - 형식 고르기

@Suite("출력 형식")
struct OutputFormatTests {

    @Test("형식이 만들 산출물을 정한다")
    func mapsToArtifacts() {
        #expect(OutputFormat.xcstrings.artifacts == ["xcstrings"])
        // 둘은 한 쌍이라 따로 고를 일이 없다.
        #expect(OutputFormat.strings.artifacts == ["strings", "stringsdict"])
    }

    /// 어느 형식을 쓰든 타입 안전 접근자는 필요하다. 형식을 바꾼다고 꺼지면 안 된다.
    @Test("형식과 무관한 산출물은 그대로 둔다")
    func keepsUnrelatedArtifacts() {
        #expect(
            OutputFormat.strings.applied(to: ["xcstrings", "swift"])
                == ["strings", "stringsdict", "swift"])
        #expect(
            OutputFormat.xcstrings.applied(to: ["strings", "stringsdict", "swift"])
                == ["xcstrings", "swift"])
    }

    @Test("형식만 바꾸면 다른 형식은 남지 않는다")
    func replacesRatherThanAdds() {
        let out = OutputFormat.xcstrings.applied(to: ["strings", "stringsdict"])
        // 두 형식이 같이 남으면 어느 쪽이 읽히는지 알 수 없게 된다.
        #expect(out.contains("strings") == false)
        #expect(out.contains("stringsdict") == false)
    }

    @Test("설정에서 형식을 되읽는다")
    func detectsFromArtifacts() {
        #expect(OutputFormat.detect(in: ["xcstrings", "swift"]) == .xcstrings)
        #expect(OutputFormat.detect(in: ["strings", "stringsdict"]) == .strings)
        #expect(OutputFormat.detect(in: ["swift"]) == nil)
    }
}

// MARK: - 세 산출물이 같은 말을 하는가

@Suite("복수형 — 형식 간 일관성")
struct PluralConsistencyTests {

    var table: LocalizationTable {
        LocalizationTable(
            sourceLocale: "ko",
            entries: [
                LocalizationEntry(key: "cart.title", values: ["ko": "장바구니", "en": "Cart"], sourceRow: 2),
                LocalizationEntry(key: "cart.items.one", values: ["en": "%d item"], sourceRow: 3),
                LocalizationEntry(
                    key: "cart.items.other", values: ["ko": "상품 %d개", "en": "%d items"],
                    sourceRow: 4),
            ])
    }

    var groups: [PluralGroup] { Plurals.split(table).groups }

    /// 평평한 키 두 개로 넣으면 Xcode 가 서로 다른 문자열로 본다.
    @Test("String Catalog 는 variations.plural 로 담는다")
    func catalogUsesVariations() throws {
        let document = XCStringsDocument(table: table, plurals: groups)

        #expect(document.strings["cart.items"] != nil)
        // 접미사 붙은 키가 따로 남으면 같은 문구가 두 군데에 생긴다.
        #expect(document.strings["cart.items.one"] == nil)
        #expect(document.strings["cart.items.other"] == nil)

        let english = try #require(document.strings["cart.items"]?.localizations?["en"])
        #expect(english.stringUnit == nil)
        #expect(english.variations?.plural["one"]?.stringUnit?.value == "%d item")
        #expect(english.variations?.plural["other"]?.stringUnit?.value == "%d items")

        // 한국어는 other 뿐이다.
        let korean = try #require(document.strings["cart.items"]?.localizations?["ko"])
        #expect(korean.variations?.plural.keys.sorted() == ["other"])
    }

    /// `itemsOne` 과 `itemsOther` 를 따로 내면 부르는 쪽이 수에 따라 골라야 한다.
    /// 그건 iOS 가 할 일이다.
    @Test("접근자는 묶음마다 하나다")
    func oneAccessorPerGroup() {
        let result = SwiftCodegen(options: .init(), tableName: "Localizable")
            .generate(table: table, plurals: groups)

        #expect(result.accessors.map(\.key).sorted() == ["cart.items", "cart.title"])
        #expect(result.source.contains("itemsOne") == false)
        #expect(result.source.contains("itemsOther") == false)
    }

    /// `%d` 자리에 String 을 넘기면 컴파일은 되고 화면에 쓰레기가 찍힌다.
    @Test("세는 인자는 Int 로 나온다")
    func countIsAnInteger() {
        let result = SwiftCodegen(options: .init(), tableName: "Localizable")
            .generate(table: table, plurals: groups)
        #expect(result.source.contains("func items(_ arg1: Int) -> String"))
    }

    /// 원문 칸이 빈 행만 보면 인자가 0 개로 잡혀 `%d item` 이 그대로 화면에 나갔다.
    @Test("원문이 비어도 인자 개수를 센다")
    func countsArgumentsWithoutASource() {
        let orphan = LocalizationTable(
            sourceLocale: "ko",
            entries: [LocalizationEntry(key: "a.one", values: ["en": "%d item"], sourceRow: 2)])
        let result = SwiftCodegen(options: .init(), tableName: "Localizable")
            .generate(table: orphan)

        #expect(result.source.contains("static var one: String") == false)
        #expect(result.source.contains("func one(_ arg1: Int) -> String"))
    }

    @Test("지정자에 맞는 Swift 타입을 고른다")
    func mapsConversionsToTypes() {
        #expect(SwiftCodegen.argumentTypes(in: "%@") == ["String"])
        #expect(SwiftCodegen.argumentTypes(in: "%d") == ["Int"])
        #expect(SwiftCodegen.argumentTypes(in: "%f") == ["Double"])
        // 위치 번호가 있으면 그 자리에 맞춘다.
        #expect(SwiftCodegen.argumentTypes(in: "%2$d개 %1$@") == ["String", "Int"])
        #expect(SwiftCodegen.argumentTypes(in: "글자만") == [])
    }
}
