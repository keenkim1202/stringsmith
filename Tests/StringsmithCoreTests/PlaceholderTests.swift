import Foundation
import Testing

@testable import StringsmithCore

@Suite("변수 파싱")
struct PlaceholderParserTests {
    let parser = PlaceholderParser()

    private func names(_ value: String) -> [String] {
        parser.parse(value).0.placeholders.map(\.identity)
    }

    @Test("중괄호 이름을 인식한다")
    func braceNames() {
        #expect(names("{name}님의 상품 {count}개") == ["name", "count"])
    }

    @Test("Apple 지정자를 인식한다")
    func appleSpecifiers() {
        #expect(names("%@님의 상품 %d개") == ["#0", "#1"])
        #expect(names("%1$@님의 상품 %2$d개") == ["$1", "$2"])
        #expect(names("%lld개 · %.2f원") == ["#0", "#1"])
    }

    @Test("%%는 리터럴 퍼센트다")
    func literalPercentEscape() {
        let (parsed, _) = parser.parse("할인율 100%%")
        #expect(parsed.placeholders.isEmpty)
        #expect(parsed.segments == [.text("할인율 100%")])
    }

    @Test("지정자가 아닌 %는 그대로 둔다 — \"50% 할인\"이 깨지면 안 된다")
    func bareLiteralPercent() {
        let (parsed, _) = parser.parse("50% 할인")
        #expect(parsed.placeholders.isEmpty)
        #expect(parsed.segments == [.text("50% 할인")])
    }

    @Test("두 표기가 한 시트에 섞여도 처리한다")
    func mixedSyntax() {
        #expect(names("{name}님 %d개") == ["name", "#1"])
    }

    @Test("자기 닫힘 XML 태그는 변수로 본다")
    func xmlSelfClosing() {
        let parser = PlaceholderParser(config: PlaceholderConfig(syntax: ["apple", "brace", "xml"]))
        let (parsed, findings) = parser.parse("<name/>님의 상품 <count/>개")
        #expect(parsed.placeholders.map(\.identity) == ["name", "count"])
        #expect(findings.unsupported.isEmpty)
    }

    @Test("짝 태그는 마크업이므로 건드리지 않고 보고한다")
    func xmlMarkupReported() {
        let parser = PlaceholderParser(config: PlaceholderConfig(syntax: ["apple", "brace", "xml"]))
        let (parsed, findings) = parser.parse("<b>중요</b>한 안내")
        #expect(parsed.placeholders.isEmpty)
        #expect(findings.unsupported == ["<b>", "</b>"])
        // 원문이 보존되어야 한다
        if case let .text(text) = parsed.segments[0] {
            #expect(text == "<b>중요</b>한 안내")
        } else {
            Issue.record("텍스트 세그먼트여야 한다")
        }
    }

    @Test("XML을 끄면 태그를 건드리지 않는다")
    func xmlDisabledByDefault() {
        let (parsed, findings) = parser.parse("<b>중요</b>")
        #expect(parsed.placeholders.isEmpty)
        #expect(findings.unsupported.isEmpty)
    }

    @Test("대괄호 표기로 바꿀 수 있다")
    func customDelimiters() {
        let parser = PlaceholderParser(
            config: PlaceholderConfig(syntax: ["brace"], braceOpen: "[", braceClose: "]"))
        #expect(parser.parse("[name]님").0.placeholders.map(\.identity) == ["name"])
    }
}

@Suite("iOS 포맷 렌더링")
struct RendererTests {
    let parser = PlaceholderParser()
    let renderer = IOSFormatRenderer()

    /// 원문으로 위치표를 만들고 대상 값을 렌더링한다.
    private func render(source: String, target: String) -> String? {
        let plan = renderer.plan(for: parser.parse(source).0)
        return renderer.render(parser.parse(target).0, using: plan)
    }

    @Test("변수 1개면 위치 번호를 붙이지 않는다")
    func singlePlaceholderIsPlain() {
        #expect(render(source: "{name}님 안녕하세요", target: "{name}님 안녕하세요") == "%@님 안녕하세요")
    }

    @Test("변수 2개 이상이면 위치 지정자를 쓴다")
    func multiplePlaceholdersArePositional() {
        #expect(render(source: "{name}님의 상품 {count}개", target: "{name}님의 상품 {count}개")
            == "%1$@님의 상품 %2$@개")
    }

    @Test("번역의 어순이 달라도 원문의 번호를 따라간다 ★")
    func reorderingFollowsSourcePositions() {
        let source = "{name}님의 상품 {count}개"
        #expect(render(source: source, target: "{count} items for {name}") == "%2$@ items for %1$@")
        #expect(render(source: source, target: "{name}さんの商品{count}点") == "%1$@さんの商品%2$@点")
    }

    @Test("변수 자리는 항상 String(%@)이다 — %d도 %@로 나간다")
    func alwaysStringType() {
        #expect(render(source: "상품 {count}개", target: "상품 {count}개") == "상품 %@개")
        #expect(render(source: "%d개 · %@", target: "%d개 · %@") == "%1$@개 · %2$@")
    }

    @Test("이미 위치 번호가 있으면 존중한다")
    func explicitPositionsPreserved() {
        #expect(render(source: "%2$@ / %1$@", target: "%2$@ / %1$@") == "%2$@ / %1$@")
    }

    @Test("변수가 있으면 리터럴 %를 이스케이프한다")
    func escapesLiteralPercentWhenFormatted() {
        #expect(render(source: "{name}님 50% 할인", target: "{name}님 50% 할인") == "%@님 50%% 할인")
    }

    @Test("변수가 없으면 %를 이스케이프하지 않는다 — 포맷 처리되지 않기 때문")
    func doesNotEscapeWhenNoPlaceholders() {
        #expect(render(source: "50% 할인", target: "50% 할인") == "50% 할인")
    }

    @Test("같은 변수를 두 번 쓰면 위치 지정자로 재사용한다 — 인자가 둘로 늘면 안 된다")
    func repeatedVariableReusesOnePosition() {
        let source = "{name}님, 안녕하세요 {name}님"
        #expect(render(source: source, target: source) == "%1$@님, 안녕하세요 %1$@님")
        #expect(
            render(source: source, target: "Hello {name}, welcome back {name}")
                == "Hello %1$@, welcome back %1$@")
        // 생성되는 접근자도 인자 하나여야 한다
        #expect(SwiftCodegen.argumentCount(in: "%1$@님, 안녕하세요 %1$@님") == 1)
    }

    @Test("대응되지 않는 이름이 있으면 nil")
    func unknownNameFails() {
        #expect(render(source: "{name}님", target: "{nickname}님") == nil)
    }
}

@Suite("변수 처리·검증")
struct PlaceholderProcessorTests {
    let processor = PlaceholderProcessor()

    private func table(_ values: [String: [String: String]]) -> LocalizationTable {
        LocalizationTable(
            sourceLocale: "ko",
            entries: values.keys.sorted().map {
                LocalizationEntry(key: $0, values: values[$0]!, sourceRow: 2)
            }
        )
    }

    @Test("전체 로케일을 원문 기준으로 변환한다")
    func convertsAllLocales() {
        let result = processor.process(
            table([
                "cart.itemCount": [
                    "ko": "{name}님의 상품 {count}개",
                    "en": "{count} items for {name}",
                    "ja": "{name}さんの商品{count}点",
                ]
            ]))
        #expect(result.errors.isEmpty)
        let values = result.table.entries[0].values
        #expect(values["ko"] == "%1$@님의 상품 %2$@개")
        #expect(values["en"] == "%2$@ items for %1$@")
        #expect(values["ja"] == "%1$@さんの商品%2$@点")
        #expect(result.conversions.count == 3)
    }

    @Test("V1a — 번역에서 변수가 누락되면 오류")
    func missingPlaceholderIsError() {
        let result = processor.process(
            table(["a": ["ko": "{name}님 {count}개", "en": "for {name}"]]))
        // 사람이 읽는 문구는 시스템 언어에 따라 바뀐다. 구조와 변수 이름으로 검증한다.
        #expect(result.errors.count == 1)
        #expect(result.errors[0].locale == "en")
        #expect(result.errors[0].message.contains("{count}"))
    }

    @Test("V1e — 원문에 없는 변수가 번역에 있으면 오류")
    func extraPlaceholderIsError() {
        let result = processor.process(
            table(["a": ["ko": "{name}님", "en": "{name} has {count}"]]))
        #expect(result.errors.count == 1)
        #expect(result.errors[0].message.contains("{count}"))
    }

    @Test("V1c — 이름 없는 변수가 2개 이상이면 경고")
    func unnamedPlaceholdersWarn() {
        let result = processor.process(table(["a": ["ko": "%@님 %d개", "en": "%@ has %d"]]))
        #expect(result.errors.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].locale == "ko")
    }

    @Test("변수가 없으면 아무것도 바꾸지 않는다")
    func noPlaceholdersNoConversion() {
        let result = processor.process(table(["a": ["ko": "설정", "en": "Settings"]]))
        #expect(result.conversions.isEmpty)
        #expect(result.issues.isEmpty)
        #expect(result.table.entries[0].values["ko"] == "설정")
    }

    @Test("V1d — 마크업 태그는 경고하고 그대로 둔다")
    func markupWarnsButPreserves() {
        let processor = PlaceholderProcessor(
            config: PlaceholderConfig(syntax: ["apple", "brace", "xml"]))
        let result = processor.process(table(["a": ["ko": "<b>중요</b> 안내"]]))
        #expect(result.errors.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.table.entries[0].values["ko"] == "<b>중요</b> 안내")
    }
}

@Suite("퍼센트 오인식 방지")
struct PercentAmbiguityTests {
    let parser = PlaceholderParser()

    @Test("\"50% off\"는 변수가 아니다 — space 플래그 + octal 오인식 방지")
    func percentSpaceLetterIsLiteral() {
        #expect(parser.parse("50% off for {name}").0.placeholders.map(\.identity) == ["name"])
        #expect(parser.parse("{name}님께 50% 할인").0.placeholders.map(\.identity) == ["name"])
    }

    @Test("8진수·포인터 지정자는 인식하지 않는다")
    func rareSpecifiersIgnored() {
        #expect(parser.parse("50%off").0.placeholders.isEmpty)
        #expect(parser.parse("100%p").0.placeholders.isEmpty)
    }

    @Test("실제로 쓰이는 지정자는 여전히 인식한다")
    func commonSpecifiersStillWork() {
        #expect(parser.parse("%@ %d %lld %.2f %s").0.placeholders.count == 5)
        #expect(parser.parse("%+d").0.placeholders.count == 1)
    }
}

@Suite("이스케이프 규칙")
struct EscapeRuleTests {
    let parser = PlaceholderParser()

    /// 파싱 결과를 "리터럴 텍스트 | 변수" 형태로 펼쳐 비교하기 쉽게 만든다.
    private func describe(_ value: String) -> String {
        parser.parse(value).0.segments.map {
            switch $0 {
            case let .text(t): return t
            case .placeholder: return "«변수»"
            }
        }.joined()
    }

    @Test("{count} — 변수")
    func plainBraceIsVariable() {
        #expect(describe("{count}") == "«변수»")
    }

    @Test(#"\{count} — 리터럴 {count}"#)
    func escapedOpenBrace() {
        #expect(describe(#"\{count}"#) == "{count}")
    }

    @Test(#"\{count\} — 리터럴 {count\}  (닫는 괄호의 \는 이스케이프가 아니라 그대로 남는다)"#)
    func escapedOpenOnlyClosingBackslashKept() {
        #expect(describe(#"\{count\}"#) == #"{count\}"#)
    }

    @Test(#"{{count}} — {«변수»}"#)
    func doubleBraceInnerIsVariable() {
        #expect(describe("{{count}}") == "{«변수»}")
    }

    @Test(#"{{{count}}} — {{«변수»}}  (몇 겹이든 안쪽이 변수)"#)
    func tripleBraceInnerIsVariable() {
        #expect(describe("{{{count}}}") == "{{«변수»}}")
    }

    @Test(#"\\{count} — 리터럴 \{count}  (앞 백슬래시는 평범한 문자)"#)
    func doubleBackslashBeforeBrace() {
        #expect(describe(#"\\{count}"#) == #"\{count}"#)
    }

    @Test(#"백슬래시는 중괄호 앞에서만 특별하다 — 그 외에는 그냥 문자"#)
    func backslashLiteralElsewhere() {
        #expect(describe(#"\\"#) == #"\\"#)
        #expect(describe(#"C:\\path"#) == #"C:\\path"#)
    }

    @Test(#"인식하지 않는 \X는 백슬래시째 남는다 — "C:\path" 가 깨지면 안 된다"#)
    func unknownEscapeIsLiteral() {
        #expect(describe(#"C:\path"#) == #"C:\path"#)
        #expect(describe(#"\d 는 이스케이프가 아니다"#) == #"\d 는 이스케이프가 아니다"#)
    }

    @Test("이스케이프한 중괄호는 변수로 세지 않는다")
    func escapedBraceNotCounted() {
        let (parsed, _) = parser.parse(#"\{count}개 · {total}원"#)
        #expect(parsed.placeholders.map(\.identity) == ["total"])
    }
}

@Suite("제어 문자 이스케이프")
struct ControlEscapeTests {
    let parser = PlaceholderParser()

    private func value(_ s: String) -> String {
        parser.parse(s).0.segments.map {
            if case let .text(t) = $0 { return t } else { return "«변수»" }
        }.joined()
    }

    @Test(#"\n 은 실제 줄바꿈이 된다 — 그대로 두면 앱에 두 글자가 보인다"#)
    func newlineEscape() {
        #expect(value(#"첫 줄\n둘째 줄"#) == "첫 줄\n둘째 줄")
    }

    @Test(#"\t 는 탭이 된다"#)
    func tabEscape() {
        #expect(value(#"이름\t값"#) == "이름\t값")
    }

    @Test("변수와 함께 있어도 동작한다")
    func withPlaceholder() {
        #expect(value(#"만 {age}세 이상\n다시 시도해 주세요"#) == "만 «변수»세 이상\n다시 시도해 주세요")
    }

    @Test("모르는 이스케이프는 그대로 둔다")
    func unknownEscapeUntouched() {
        #expect(value(#"C:\path"#) == #"C:\path"#)
        #expect(value(#"\d"#) == #"\d"#)
    }

    @Test("중괄호 이스케이프가 우선한다")
    func braceEscapeStillWorks() {
        #expect(value(#"\{count}"#) == "{count}")
        #expect(value(#"\\{count}"#) == #"\{count}"#)
    }
}

@Suite("리터럴 대괄호 (실제 시트에서 나온 케이스)")
struct LiteralBracketTests {
    let parser = PlaceholderParser()

    @Test("[필수]·[선택] 같은 리터럴 대괄호는 경고 없이 통과한다")
    func koreanBracketsAreNotWarned() {
        for sample in ["[필수] 이용약관 동의", "[Optional] Marketing", "[任意] 利用規約", "[고객센터]로 문의"] {
            let (parsed, findings) = parser.parse(sample)
            #expect(parsed.placeholders.isEmpty)
            #expect(findings.unsupported.isEmpty)
        }
    }
}
