import Foundation
import Testing

@testable import StringsmithCore

@Suite("가져오기: 변수")
struct ImportPlaceholderTests {

    @Test("이름 없는 지정자는 나온 순서로 번호를 받는다")
    func unnamedGetOrdinals() {
        let (out, found) = LocalizationImport.convertPlaceholders("%@ has %@")
        #expect(out == "{arg1} has {arg2}")
        #expect(found)
    }

    /// 어순이 바뀐 번역끼리 이어지려면 번호가 같아야 한다. 위치 지정자가 그 번호다.
    @Test("위치 지정자는 어순이 바뀌어도 같은 이름이 된다")
    func positionalKeepsIdentity() {
        let ko = LocalizationImport.convertPlaceholders("%1$@님의 상품 %2$@개").0
        let en = LocalizationImport.convertPlaceholders("%2$@ items for %1$@").0
        #expect(ko == "{arg1}님의 상품 {arg2}개")
        #expect(en == "{arg2} items for {arg1}")
    }

    @Test("겹친 퍼센트는 글자 하나로 돌아온다")
    func literalPercent() {
        #expect(LocalizationImport.convertPlaceholders("%@ 50%% off").0 == "{arg1} 50% off")
    }

    /// 이스케이프하지 않으면 다음 generate 에서 변수로 읽힌다.
    @Test("원문의 중괄호는 이스케이프한다")
    func bracesEscaped() {
        #expect(LocalizationImport.convertPlaceholders("{not a variable}").0 == "\\{not a variable}")
        #expect(LocalizationImport.convertPlaceholders("a \\ b").0 == "a \\\\ b")
    }

    @Test("변수가 없으면 없다고 알린다")
    func reportsAbsence() {
        #expect(LocalizationImport.convertPlaceholders("plain").1 == false)
    }

    /// `%@` 가 되면 `.stringsdict` 가 수를 못 봐서 런타임에 범주 선택이 깨진다.
    @Test("복수형에서 세는 변수만 count 라는 이름을 받는다")
    func pluralCountIsNamed() {
        #expect(LocalizationImport.convertPlaceholders("%d items", countVariable: "count").0
            == "{count} items")
        // 복수형이 아니면 정수도 그냥 번호다. 이 도구의 슬롯은 전부 String 이다.
        #expect(LocalizationImport.convertPlaceholders("%d items").0 == "{arg1} items")
        // 길이 수식어가 붙어도 정수는 정수다.
        #expect(LocalizationImport.convertPlaceholders("%lld", countVariable: "count").0
            == "{count}")
    }

    @Test("복수형에 정수가 둘이면 첫 번째만 count 다")
    func onlyFirstIntegerIsCount() {
        let out = LocalizationImport.convertPlaceholders("%1$d of %2$d", countVariable: "count").0
        #expect(out == "{count} of {arg2}")
    }
}

@Suite("가져오기: String Catalog")
struct ImportCatalogTests {

    static func write(_ json: String) throws -> String {
        let directory = NSTemporaryDirectory() + "/ss-import-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/Localizable.xcstrings"
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("평범한 항목은 한 행이 된다")
    func plainEntries() throws {
        let path = try Self.write("""
            {"sourceLanguage":"ko","version":"1.0","strings":{
              "cart.title":{"comment":"장바구니 제목","localizations":{
                "ko":{"stringUnit":{"state":"translated","value":"장바구니"}},
                "en":{"stringUnit":{"state":"translated","value":"Cart"}}}}}}
            """)
        let result = try LocalizationImport.read(path: path)
        #expect(result.sourceLocale == "ko")
        #expect(result.locales == ["ko", "en"])
        #expect(result.rows == [
            ["key", "description", "ko", "en"],
            ["cart.title", "장바구니 제목", "장바구니", "Cart"],
        ])
    }

    /// 시트는 복수형을 키 접미사로 적는다. 카탈로그의 variations 를 거기로 편다.
    @Test("복수형은 키 접미사 행으로 펴진다")
    func pluralsBecomeSuffixes() throws {
        let path = try Self.write("""
            {"sourceLanguage":"en","version":"1.0","strings":{
              "cart.items":{"localizations":{
                "en":{"variations":{"plural":{
                  "one":{"stringUnit":{"state":"translated","value":"%lld item"}},
                  "other":{"stringUnit":{"state":"translated","value":"%lld items"}}}}}}}}}
            """)
        let result = try LocalizationImport.read(path: path)
        #expect(result.rows == [
            ["key", "en"],
            ["cart.items.one", "{count} item"],
            ["cart.items.other", "{count} items"],
        ])
    }

    @Test("CLDR 밖의 범주는 옮기지 않고 알린다")
    func unknownCategoryIsReported() throws {
        let path = try Self.write("""
            {"sourceLanguage":"en","version":"1.0","strings":{
              "x":{"localizations":{"en":{"variations":{"plural":{
                "manyish":{"stringUnit":{"state":"translated","value":"v"}}}}}}}}}
            """)
        let result = try LocalizationImport.read(path: path)
        #expect(result.skipped.contains { $0.contains("manyish") })
    }

    /// 카탈로그는 기기별 변형도 variations 에 담는다. 필수 필드로 두면 그런 키 하나가
    /// 파일 전체의 디코딩을 막아, 나머지 299개까지 못 읽게 된다.
    @Test("기기별 변형은 그 키만 건너뛴다")
    func deviceVariationSkipsOnlyThatKey() throws {
        let path = try Self.write("""
            {"sourceLanguage":"en","version":"1.0","strings":{
              "ok":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"OK"}}}},
              "welcome":{"localizations":{"en":{"variations":{"device":{
                "iphone":{"stringUnit":{"state":"translated","value":"Tap"}}}}}}}}}
            """)
        let result = try LocalizationImport.read(path: path)
        #expect(result.rows == [["key", "en"], ["ok", "OK"]])
        #expect(result.skipped.count == 1)
        #expect(result.skipped[0].contains("welcome"))
    }

    /// 파서가 `%#` 를 플래그로 읽어 `{arg1}count@` 같은 그럴듯한 쓰레기를 만든다.
    /// 조용히 틀린 값이 시트에 남는 게 이 도구에서 제일 나쁜 결과다.
    @Test("치환은 망가진 값을 만드느니 건너뛴다")
    func substitutionsAreSkipped() throws {
        let path = try Self.write("""
            {"sourceLanguage":"en","version":"1.0","strings":{
              "ok":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"OK"}}}},
              "found":{"localizations":{"en":{"stringUnit":{
                "state":"translated","value":"Found %#@count@ in %#@places@"}}}}}}
            """)
        let result = try LocalizationImport.read(path: path)
        #expect(result.rows == [["key", "en"], ["ok", "OK"]])
        #expect(result.skipped.contains { $0.contains("found") })
    }

    @Test("String Catalog 이 아니면 그렇게 말한다")
    func rejectsNonCatalog() throws {
        let path = try Self.write("{\"nope\":1}")
        #expect(throws: StringsmithError.self) {
            _ = try LocalizationImport.read(path: path)
        }
    }
}

@Suite("가져오기: .lproj")
struct ImportLprojTests {

    static func makeTree(_ files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "/ss-lproj-\(UUID().uuidString)"
        for (relative, contents) in files {
            let path = root + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }
        return root
    }

    @Test("로케일마다 한 열이 된다")
    func columnsPerLocale() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.strings": "\"a\" = \"A\";\n",
            "ko.lproj/Localizable.strings": "\"a\" = \"가\";\n",
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.sourceLocale == "en")
        #expect(result.rows == [["key", "en", "ko"], ["a", "A", "가"]])
    }

    /// 번역가가 읽는 설명이다. plist 파서가 주석을 버리므로 따로 훑어야 한다.
    @Test("주석은 description 열로 옮긴다")
    func commentsBecomeDescriptions() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.strings": """
                /* 장바구니 — 화면 제목 */
                "cart.title" = "Cart";
                """
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.rows == [
            ["key", "description", "en"],
            ["cart.title", "장바구니 — 화면 제목", "Cart"],
        ])
    }

    @Test("Base.lproj 는 로케일이 아니다")
    func skipsBase() throws {
        let root = try Self.makeTree([
            "Base.lproj/Localizable.strings": "\"a\" = \"A\";\n",
            "en.lproj/Localizable.strings": "\"a\" = \"A\";\n",
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.locales == ["en"])
        #expect(result.skipped.contains { $0.contains("Base.lproj") })
    }

    /// 형식 문자열에 앞뒤 문장이 붙는 게 흔하다. 값만 떼면 뜻이 반쯤 사라진다.
    @Test("stringsdict 의 앞뒤 문장까지 살린다")
    func keepsSurroundingText() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.stringsdict": """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>cart.left</key>
                  <dict>
                    <key>NSStringLocalizedFormatKey</key><string>You have %#@n@ left</string>
                    <key>n</key>
                    <dict>
                      <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
                      <key>NSStringFormatValueTypeKey</key><string>d</string>
                      <key>one</key><string>%d item</string>
                      <key>other</key><string>%d items</string>
                    </dict>
                  </dict>
                </dict></plist>
                """
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.rows == [
            ["key", "en"],
            ["cart.left.one", "You have {count} item left"],
            ["cart.left.other", "You have {count} items left"],
        ])
    }

    @Test("변수가 둘 이상인 복수형은 옮기지 않고 알린다")
    func skipsMultiVariablePlurals() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.stringsdict": """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>both</key>
                  <dict>
                    <key>NSStringLocalizedFormatKey</key><string>%#@a@ and %#@b@</string>
                  </dict>
                </dict></plist>
                """,
            "en.lproj/Localizable.strings": "\"x\" = \"X\";\n",
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.skipped.contains { $0.contains("both") })
    }

    /// 말없이 절반만 옮기면 없어진 걸 아무도 모른다.
    @Test("읽지 않은 테이블은 이름을 대고 알린다")
    func namesTheTablesItSkipped() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.strings": "\"a\" = \"A\";\n",
            "en.lproj/Errors.strings": "\"e\" = \"E\";\n",
        ])
        let result = try LocalizationImport.read(path: root)
        #expect(result.rows == [["key", "en"], ["a", "A"]])
        #expect(result.skipped.contains { $0.contains("Errors.strings") })
    }

    @Test("--table 로 다른 테이블을 읽는다")
    func readsAnotherTable() throws {
        let root = try Self.makeTree([
            "en.lproj/Localizable.strings": "\"a\" = \"A\";\n",
            "en.lproj/Errors.strings": "\"e\" = \"E\";\n",
        ])
        let result = try LocalizationImport.read(path: root, table: "Errors")
        #expect(result.rows == [["key", "en"], ["e", "E"]])
    }

    @Test("읽을 게 없으면 그렇게 말한다")
    func emptyDirectory() throws {
        let root = try Self.makeTree(["README.md": "nothing here"])
        #expect(throws: StringsmithError.self) {
            _ = try LocalizationImport.read(path: root)
        }
    }
}
