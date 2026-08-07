import Foundation
import Testing

@testable import StringsmithCore

@Suite("Swift 접근자 생성")
struct SwiftCodegenTests {

    private func table(_ entries: [LocalizationEntry]) -> LocalizationTable {
        LocalizationTable(sourceLocale: "ko", entries: entries)
    }

    private func generate(
        _ entries: [LocalizationEntry],
        options: SwiftCodegen.Options = SwiftCodegen.Options()
    ) -> String {
        SwiftCodegen(options: options).generate(table: table(entries)).source
    }

    @Test("키 앞머리를 네임스페이스로 쪼갠다")
    func keyPrefixNamespace() {
        let source = generate([
            LocalizationEntry(key: "order_cancel_confirm_body", values: ["ko": "삭제할까요?"])
        ])
        #expect(source.contains("public enum Order {"))
        #expect(source.contains("static var cancelConfirmBody: String"))
    }

    @Test("점 표기도 네임스페이스가 된다")
    func dottedKeyNamespace() {
        let source = generate([LocalizationEntry(key: "cart.empty", values: ["ko": "비었습니다"])])
        #expect(source.contains("public enum Cart {"))
        #expect(source.contains("static var empty: String"))
    }

    @Test("구분자가 없는 키는 최상위에 둔다")
    func flatKey() {
        let source = generate([LocalizationEntry(key: "confirm", values: ["ko": "확인"])])
        #expect(!source.contains("public enum Confirm {"))
        #expect(source.contains("static var confirm: String"))
    }

    @Test("변수 개수만큼 String 파라미터를 만든다 — 타입은 항상 String")
    func argumentsAreStrings() {
        let source = generate([
            LocalizationEntry(key: "cart_itemCount", values: ["ko": "%1$@님의 상품 %2$@개"]),
            LocalizationEntry(key: "cart_greeting", values: ["ko": "%@님 안녕하세요"]),
        ])
        #expect(source.contains("func itemCount(_ arg1: String, _ arg2: String) -> String"))
        #expect(source.contains("func greeting(_ arg1: String) -> String"))
    }

    @Test("위치 지정자의 최대 번호로 파라미터 개수를 정한다")
    func positionalArgumentCount() {
        // 같은 변수를 두 번 써도 파라미터는 2개다
        let source = generate([
            LocalizationEntry(key: "a_b", values: ["ko": "%1$@ / %2$@ / %1$@"])
        ])
        #expect(source.contains("(_ arg1: String, _ arg2: String)"))
    }

    @Test("Swift 예약어는 백틱으로 감싼다")
    func keywordEscaping() {
        let source = generate([
            LocalizationEntry(key: "common_default", values: ["ko": "기본"]),
            LocalizationEntry(key: "common_return", values: ["ko": "돌아가기"]),
        ])
        #expect(source.contains("static var `default`: String"))
        #expect(source.contains("static var `return`: String"))
    }

    @Test("이름이 겹치면 접미사를 붙이고 보고한다")
    func collisionsAreReported() {
        let result = SwiftCodegen().generate(
            table: table([
                LocalizationEntry(key: "a_hello_world", values: ["ko": "1"]),
                LocalizationEntry(key: "a_hello-world", values: ["ko": "2"]),
            ]))
        #expect(result.collisions.count == 1)
        #expect(result.source.contains("helloWorld2"))
    }

    @Test("원문과 설명을 doc 주석에 넣는다")
    func docComments() {
        let source = generate([
            LocalizationEntry(
                key: "cart_empty", screen: "장바구니", comment: "빈 상태 안내",
                values: ["ko": "장바구니가 비었습니다"])
        ])
        #expect(source.contains("/// 장바구니 — 빈 상태 안내"))
        #expect(source.contains(#"/// ko: "장바구니가 비었습니다""#))
    }

    @Test("doc 주석 빈 줄에 후행 공백을 남기지 않는다")
    func noTrailingWhitespace() {
        let source = generate([
            LocalizationEntry(key: "a_b", screen: "화면", values: ["ko": "값"])
        ])
        #expect(!source.contains("/// \n"))
    }

    @Test("줄바꿈은 주석에서 이스케이프해 한 줄로 만든다")
    func newlineInDocComment() {
        let source = generate([
            LocalizationEntry(key: "a_b", values: ["ko": "첫 줄\n둘째 줄"])
        ])
        #expect(source.contains(#"ko: "첫 줄\n둘째 줄""#))
        #expect(!source.contains("/// ko: \"첫 줄\n"))
    }

    @Test("namespace 를 screen 으로 바꿀 수 있다")
    func screenNamespace() {
        let source = generate(
            [LocalizationEntry(key: "empty", screen: "장바구니", values: ["ko": "비었습니다"])],
            options: SwiftCodegen.Options(namespace: "screen")
        )
        #expect(source.contains("public enum 장바구니 {"))
    }

    @Test("namespace: none 은 평면으로 만든다")
    func noNamespace() {
        let source = generate(
            [LocalizationEntry(key: "cart_empty", values: ["ko": "비었습니다"])],
            options: SwiftCodegen.Options(namespace: "none")
        )
        #expect(!source.contains("enum Cart"))
        #expect(source.contains("static var cartEmpty: String"))
    }

    @Test("SPM 리소스 번들을 고를 수 있다")
    func moduleBundle() {
        let source = generate(
            [LocalizationEntry(key: "a", values: ["ko": "값"])],
            options: SwiftCodegen.Options(bundle: "module")
        )
        #expect(source.contains("Bundle.module"))
    }

    @Test("키에 따옴표·백슬래시가 있어도 문자열 리터럴이 깨지지 않는다")
    func escapedKeyLiteral() {
        let source = generate([LocalizationEntry(key: #"a_b"c\d"#, values: ["ko": "값"])])
        #expect(source.contains(#"\"c\\d"#))
    }

    @Test("출력이 결정적이다 — 같은 입력이면 같은 소스")
    func deterministic() {
        let entries = [
            LocalizationEntry(key: "z_one", values: ["ko": "1"]),
            LocalizationEntry(key: "a_two", values: ["ko": "2"]),
        ]
        #expect(generate(entries) == generate(entries))
        // 네임스페이스가 정렬되어 나온다
        let source = generate(entries)
        #expect(source.range(of: "enum A")!.lowerBound < source.range(of: "enum Z")!.lowerBound)
    }
}

@Suite("생성된 코드의 포맷 동작")
struct GeneratedFormatSemanticsTests {

    /// 생성 코드가 쓰는 `String(format:locale:arguments:)` 의미를 고정한다.
    @Test("위치 지정자가 어순이 바뀐 번역에서도 올바르게 채워진다")
    func positionalSubstitution() {
        let ko = String(format: "%1$@님의 상품 %2$@개", locale: .current, arguments: ["민수", "3"])
        let en = String(format: "%2$@ items for %1$@", locale: .current, arguments: ["민수", "3"])
        #expect(ko == "민수님의 상품 3개")
        #expect(en == "3 items for 민수")
    }

    @Test("이스케이프한 퍼센트는 포맷 후 하나로 돌아온다")
    func escapedPercent() {
        #expect(String(format: "%@님께 50%% 할인", locale: .current, arguments: ["민수"])
            == "민수님께 50% 할인")
    }
}
