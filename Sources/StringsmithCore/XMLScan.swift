import Foundation

/// 엑셀이 쓰는 XML 에서 필요한 것만 꺼낸다.
///
/// `XMLParser` 를 델리게이트로 쓰는 대신 직접 훑는다. 필요한 게 셋뿐이고 — 속성, 문자열
/// 표, 셀 — 각각 형태가 정해져 있어서, 델리게이트 상태 기계를 세 벌 만드는 것보다 짧다.
enum XMLScan {

    // MARK: - 속성

    /// `<sheet name="..." .../>` 같은 요소의 속성들.
    static func attributes(in data: Data, element: String) -> [[String: String]] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [[String: String]] = []
        var index = text.startIndex

        while let open = text.range(of: "<\(element) ", range: index..<text.endIndex) {
            guard let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else {
                break
            }
            out.append(parseAttributes(String(text[open.upperBound..<close.lowerBound])))
            index = close.upperBound
        }
        return out
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var index = text.startIndex

        while let equals = text.range(of: "=\"", range: index..<text.endIndex) {
            let name = text[index..<equals.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let end = text.range(of: "\"", range: equals.upperBound..<text.endIndex)
            else { break }
            out[name] = unescape(String(text[equals.upperBound..<end.lowerBound]))
            index = end.upperBound
        }
        return out
    }

    // MARK: - 문자열 표

    /// `<si>` 하나가 문자열 하나다.
    ///
    /// 서식이 섞인 칸은 `<si><r><t>가</t></r><r><t>나</t></r></si>` 처럼 조각으로 쪼개져
    /// 있다. 이어 붙이지 않으면 "가나" 가 "가" 로 잘린다.
    static func sharedStrings(in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [String] = []

        for item in blocks(in: text, element: "si") {
            var value = ""
            for piece in blocks(in: item, element: "t") { value += unescape(piece) }
            out.append(value)
        }
        return out
    }

    // MARK: - 셀

    struct Cell {
        var reference: String
        var type: String
        var value: String
        var inline: String
    }

    /// 행마다 셀 목록.
    static func rows(in data: Data) -> [[Cell]] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [[Cell]] = []

        for row in blocks(in: text, element: "row", keepingSelfClosing: true) {
            var cells: [Cell] = []
            for (attributes, body) in elements(in: row, element: "c") {
                cells.append(
                    Cell(
                        reference: attributes["r"] ?? "",
                        type: attributes["t"] ?? "",
                        value: blocks(in: body, element: "v").first.map(unescape) ?? "",
                        inline: blocks(in: body, element: "t").map(unescape).joined()
                    ))
            }
            out.append(cells)
        }
        return out
    }

    // MARK: - 훑기

    /// `<name ...>본문</name>` 의 본문들.
    ///
    /// - Parameter keepingSelfClosing: `<row/>` 처럼 내용 없는 것도 빈 본문으로 센다.
    ///   행은 비어 있어도 자리를 지켜야 하지만, `<t/>` 같은 건 셀 필요가 없다.
    static func blocks(
        in text: String, element: String, keepingSelfClosing: Bool = false
    ) -> [String] {
        var out: [String] = []
        for (_, body) in elements(in: text, element: element, keepingSelfClosing: keepingSelfClosing)
        {
            out.append(body)
        }
        return out
    }

    /// 여는 태그의 속성과 본문을 함께.
    static func elements(
        in text: String, element: String, keepingSelfClosing: Bool = false
    ) -> [(attributes: [String: String], body: String)] {
        var out: [(attributes: [String: String], body: String)] = []
        var index = text.startIndex

        while index < text.endIndex,
            let open = text.range(of: "<\(element)", range: index..<text.endIndex)
        {
            // `<c ...>` 를 찾을 때 `<col ...>` 에 걸리면 안 된다.
            let following = open.upperBound
            if following < text.endIndex {
                let next = text[following]
                guard next == " " || next == ">" || next == "/" else {
                    index = following
                    continue
                }
            }
            guard let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else {
                break
            }
            let head = String(text[open.upperBound..<close.lowerBound])

            if head.hasSuffix("/") {
                // 내용 없는 태그.
                if keepingSelfClosing {
                    out.append((parseAttributes(String(head.dropLast())), ""))
                }
                index = close.upperBound
                continue
            }

            guard
                let end = text.range(of: "</\(element)>", range: close.upperBound..<text.endIndex)
            else { break }
            out.append((parseAttributes(head), String(text[close.upperBound..<end.lowerBound])))
            index = end.upperBound
        }
        return out
    }

    // MARK: - 이스케이프

    /// XML 실체 참조를 되돌린다.
    ///
    /// `&amp;` 를 마지막에 푸는 게 중요하다. 먼저 풀면 `&amp;lt;` 가 `<` 가 되어 원래
    /// 글자였던 `&lt;` 를 태그로 바꿔 놓는다.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        // 숫자 참조. 엑셀이 제어문자를 이렇게 쓴다.
        out = replaceNumericReferences(in: out)
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func replaceNumericReferences(in text: String) -> String {
        guard text.contains("&#") else { return text }
        var out = ""
        var index = text.startIndex

        while let start = text.range(of: "&#", range: index..<text.endIndex) {
            out += text[index..<start.lowerBound]
            guard let end = text.range(of: ";", range: start.upperBound..<text.endIndex) else {
                out += text[start.lowerBound...]
                return out
            }
            let digits = text[start.upperBound..<end.lowerBound]
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            } else {
                out += text[start.lowerBound..<end.upperBound]
            }
            index = end.upperBound
        }
        out += text[index...]
        return out
    }
}
