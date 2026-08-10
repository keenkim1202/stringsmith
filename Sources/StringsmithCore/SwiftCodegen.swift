import Foundation

/// 로컬라이제이션 테이블에서 타입세이프 Swift 접근자를 만든다.
///
/// Apple의 `xcstringstool generate-symbols`와 다른 점:
/// - **계층 네임스페이스** — `L10n.Order.cancelConfirmBody`. Apple 것은 평면이라 키가 많으면 자동완성이 무의미해진다
/// - **`String` 반환** — `LocalizedStringResource`는 iOS 16+ 를 요구한다
/// - **시트의 맥락을 안다** — 화면·설명 컬럼과 원문 값을 doc 주석에 넣는다
public struct SwiftCodegen: Sendable {

    public struct Options: Codable, Sendable, Equatable {
        /// 최상위 enum 이름.
        public var enumName: String
        /// `keyPrefix`: 키의 첫 조각(`order_cancel_body` → `Order`)
        /// `screen`: 화면 컬럼 값
        /// `none`: 평면
        public var namespace: String
        /// `main`: `Bundle.main` — 앱 타깃. `module`: `Bundle.module` — SPM 리소스.
        public var bundle: String
        public var accessLevel: String
        /// 원문 값과 설명을 doc 주석에 넣는다.
        public var docComments: Bool

        public init(
            enumName: String = "L10n",
            namespace: String = "keyPrefix",
            bundle: String = "main",
            accessLevel: String = "public",
            docComments: Bool = true
        ) {
            self.enumName = enumName
            self.namespace = namespace
            self.bundle = bundle
            self.accessLevel = accessLevel
            self.docComments = docComments
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enumName = try c.decodeIfPresent(String.self, forKey: .enumName) ?? "L10n"
            namespace = try c.decodeIfPresent(String.self, forKey: .namespace) ?? "keyPrefix"
            bundle = try c.decodeIfPresent(String.self, forKey: .bundle) ?? "main"
            accessLevel = try c.decodeIfPresent(String.self, forKey: .accessLevel) ?? "public"
            docComments = try c.decodeIfPresent(Bool.self, forKey: .docComments) ?? true
        }
    }

    public let options: Options
    public let tableName: String

    public init(options: Options = Options(), tableName: String = "Localizable") {
        self.options = options
        self.tableName = tableName
    }

    public struct Result: Sendable {
        public var source: String
        /// 이름이 충돌해 접미사를 붙인 항목.
        public var collisions: [Collision]
        /// 키마다 만들어진 접근자 경로. 드리프트 검출이 코드에서 이걸 찾는다.
        public var accessors: [Accessor]
    }

    /// 키 하나에 대해 만들어진 Swift 접근자.
    public struct Accessor: Sendable, Equatable {
        public var key: String
        /// `L10n.home.title` 같은 전체 경로.
        public var path: String
        /// 시트에서의 자리.
        public var location: String
    }

    /// 같은 Swift 이름이 되어 접미사를 붙인 키.
    public struct Collision: Sendable, Equatable {
        public var key: String
        /// 접미사를 붙인 뒤의 이름.
        public var identifier: String
        /// 시트에서의 자리. 고칠 곳은 코드가 아니라 시트다.
        public var location: String
    }

    // MARK: - 생성

    public func generate(table: LocalizationTable, plurals: [PluralGroup] = []) -> Result {
        var collisions: [Collision] = []
        var accessors: [Accessor] = []

        // 복수형으로 묶인 행은 개별 접근자를 만들지 않는다. `itemsOne` 과 `itemsOther` 를
        // 따로 내면 부르는 쪽이 수에 따라 직접 골라야 하는데, 그건 iOS 가 할 일이다.
        var absorbed = Set<String>()
        for group in plurals {
            for entry in group.variants.values { absorbed.insert(entry.key) }
        }

        var members = table.entries.filter { !absorbed.contains($0.key) }.map { entry in
            Member(
                entry: entry,
                namespace: namespaceName(for: entry),
                identifier: Self.lowerCamel(memberBase(for: entry)),
                argumentTypes: Self.argumentTypes(in: Self.reference(for: entry, in: table))
            )
        }

        for group in plurals {
            // 묶음을 대표하는 행 하나. 접미사를 뗀 키로 갈아 끼운다.
            guard let anchor = group.variants[.other] ?? group.variants.sorted(by: {
                $0.key < $1.key
            }).first?.value else { continue }
            var entry = anchor
            entry.key = group.key

            members.append(
                Member(
                    entry: entry,
                    namespace: namespaceName(for: entry),
                    identifier: Self.lowerCamel(memberBase(for: entry)),
                    argumentTypes: Self.argumentTypes(in: Self.reference(for: entry, in: table))
                ))
        }
        members.sort { $0.entry.key < $1.entry.key }

        // 네임스페이스별로 묶고, 같은 이름이 겹치면 결정적으로 구분한다.
        var grouped: [String: [Member]] = [:]
        for member in members {
            grouped[member.namespace, default: []].append(member)
        }

        var out = header()
        out += "\(options.accessLevel) enum \(options.enumName) {\n"

        for namespace in grouped.keys.sorted() {
            var used = Set<String>()
            let sorted = grouped[namespace]!.sorted { $0.entry.key < $1.entry.key }
            let indent = namespace.isEmpty ? "    " : "        "

            if !namespace.isEmpty {
                out += "\n    \(options.accessLevel) enum \(namespace) {\n"
            } else {
                out += "\n"
            }

            for var member in sorted {
                if used.contains(member.identifier) {
                    var suffix = 2
                    while used.contains("\(member.identifier)\(suffix)") { suffix += 1 }
                    collisions.append(
                        Collision(
                            key: member.entry.key,
                            identifier: "\(member.identifier)\(suffix)",
                            location: member.entry.sourceLabel))
                    member.identifier = "\(member.identifier)\(suffix)"
                }
                used.insert(member.identifier)
                accessors.append(
                    Accessor(
                        key: member.entry.key,
                        path: [options.enumName, namespace, member.identifier]
                            .filter { !$0.isEmpty }.joined(separator: "."),
                        location: member.entry.sourceLabel))
                out += render(member, table: table, indent: indent)
            }

            if !namespace.isEmpty { out += "    }\n" }
        }

        out += "}\n"
        out += lookupHelper()
        return Result(source: out, collisions: collisions, accessors: accessors)
    }

    // MARK: - 조각

    struct Member {
        var entry: LocalizationEntry
        var namespace: String
        var identifier: String
        var argumentTypes: [String]

        var argumentCount: Int { argumentTypes.count }
    }

    private func render(_ member: Member, table: LocalizationTable, indent: String) -> String {
        var out = "\n"
        if options.docComments {
            for line in docLines(for: member.entry, table: table) {
                // 빈 줄에 후행 공백을 남기지 않는다 (린터가 잡는다).
                out += line.isEmpty ? "\(indent)///\n" : "\(indent)/// \(line)\n"
            }
        }
        let key = Self.escapedStringLiteral(member.entry.key)
        let name = Self.escapedIdentifier(member.identifier)

        if member.argumentCount == 0 {
            out += "\(indent)\(options.accessLevel) static var \(name): String {\n"
            out += "\(indent)    \(options.enumName).lookUp(\(key))\n"
            out += "\(indent)}\n"
        } else {
            // 변수 자리는 항상 String 이다 (Placeholder.swift 참고).
            let params = member.argumentTypes.enumerated()
                .map { "_ arg\($0.offset + 1): \($0.element)" }
                .joined(separator: ", ")
            let args = (1...member.argumentCount).map { "arg\($0)" }.joined(separator: ", ")
            out += "\(indent)\(options.accessLevel) static func \(name)(\(params)) -> String {\n"
            out += "\(indent)    \(options.enumName).lookUp(\(key), \(args))\n"
            out += "\(indent)}\n"
        }
        return out
    }

    private func docLines(for entry: LocalizationEntry, table: LocalizationTable) -> [String] {
        var lines: [String] = []
        if let comment = XCStringsDocument.comment(for: entry) {
            lines.append(comment)
            lines.append("")
        }
        // 원문을 함께 보여주면 자동완성만 봐도 어떤 문구인지 안다.
        if let source = entry.values[table.sourceLocale] {
            lines.append("\(table.sourceLocale): \"\(source.replacingOccurrences(of: "\n", with: "\\n"))\"")
        }
        return lines
    }

    private func header() -> String {
        """
        // Generated by stringsmith. DO NOT EDIT.
        //
        // 이 파일은 스프레드시트에서 생성됩니다. 직접 고치면 다음 실행에 덮어써집니다.

        import Foundation

        // swiftlint:disable all
        // swift-format-ignore-file


        """
    }

    private func lookupHelper() -> String {
        let bundleExpression: String
        switch options.bundle {
        case "module": bundleExpression = "Bundle.module"
        default: bundleExpression = "Bundle.main"
        }
        return """

            extension \(options.enumName) {
                private static let bundle: Bundle = \(bundleExpression)

                fileprivate static func lookUp(_ key: String, _ arguments: CVarArg...) -> String {
                    let format = NSLocalizedString(
                        key, tableName: "\(tableName)", bundle: bundle, value: key, comment: ""
                    )
                    guard !arguments.isEmpty else { return format }
                    return String(format: format, locale: .current, arguments: arguments)
                }
            }

            """
    }

    // MARK: - 이름 만들기

    func namespaceName(for entry: LocalizationEntry) -> String {
        switch options.namespace {
        case "none":
            return ""
        case "screen":
            let screen = entry.screen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return screen.isEmpty ? "" : Self.upperCamel(screen)
        default:  // keyPrefix
            guard let separator = entry.key.first(where: { $0 == "_" || $0 == "." }),
                let head = entry.key.split(separator: separator).first,
                entry.key.split(separator: separator).count >= 2
            else { return "" }
            return Self.upperCamel(String(head))
        }
    }

    func memberBase(for entry: LocalizationEntry) -> String {
        guard options.namespace != "none" else { return entry.key }
        let namespace = namespaceName(for: entry)
        guard !namespace.isEmpty, options.namespace != "screen" else { return entry.key }
        // 네임스페이스로 쓴 첫 조각은 멤버 이름에서 뺀다: order_cancel_body → cancelBody
        if let separator = entry.key.first(where: { $0 == "_" || $0 == "." }) {
            let parts = entry.key.split(separator: separator)
            if parts.count >= 2 {
                return parts.dropFirst().joined(separator: String(separator))
            }
        }
        return entry.key
    }

    // MARK: - 식별자 유틸

    static func components(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func upperCamel(_ s: String) -> String {
        let joined = components(s).map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
        return sanitizeLeading(joined)
    }

    static func lowerCamel(_ s: String) -> String {
        let parts = components(s)
        guard let first = parts.first else { return "_" }
        let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        // 첫 조각이 이미 대문자로 시작하면(약어 등) 그대로 둔다.
        let head = first.first?.isUppercase == true ? first : first.prefix(1).lowercased() + first.dropFirst()
        return sanitizeLeading(head + rest.joined())
    }

    /// Swift 식별자는 숫자로 시작할 수 없다.
    private static func sanitizeLeading(_ s: String) -> String {
        guard let first = s.first else { return "_" }
        return first.isNumber ? "_" + s : s
    }

    /// Swift 예약어면 백틱으로 감싼다.
    static func escapedIdentifier(_ s: String) -> String {
        keywords.contains(s) ? "`\(s)`" : s
    }

    static func escapedStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// 원문에 들어 있는 포맷 지정자 개수. 위치 지정자가 있으면 최대 번호를 쓴다.
    static func argumentCount(in value: String) -> Int {
        argumentTypes(in: value).count
    }

    /// 자리마다의 Swift 타입.
    ///
    /// 거의 전부 `String` 이다. 예외는 복수형에서 세는 변수로, `%d` 로 나가므로 `Int` 여야
    /// 한다 — `String` 을 넘기면 `CVarArg` 로는 통과하지만 화면에 쓰레기가 찍힌다.
    static func argumentTypes(in value: String) -> [String] {
        let parser = PlaceholderParser(config: PlaceholderConfig(syntax: ["apple"]))
        let placeholders = parser.parse(value).0.placeholders
        guard !placeholders.isEmpty else { return [] }

        let count = placeholders.compactMap(\.explicitPosition).max() ?? placeholders.count
        var types = [String](repeating: "String", count: count)
        for (index, placeholder) in placeholders.enumerated() {
            let position = (placeholder.explicitPosition ?? index + 1) - 1
            guard position >= 0, position < count else { continue }
            // %d·%u 계열은 정수, %f 계열은 실수. 나머지는 String 이다.
            switch placeholder.conversion {
            case "d", "D", "i", "u", "U": types[position] = "Int"
            case "f", "F", "e", "E", "g", "G": types[position] = "Double"
            default: break
            }
        }
        return types
    }

    /// 인자 개수를 셀 기준 값.
    ///
    /// 보통은 원문이다. 복수형에서 **원문 언어가 쓰지 않는 범주**는 원문 칸이 비는데, 그때
    /// 원문만 보면 인자가 0 개로 잡혀 `%@` 가 그대로 화면에 찍힌다. 값이 있는 아무 로케일이나
    /// 대신 본다 — 어차피 자리 수는 언어마다 같아야 하고, 다르면 검증이 먼저 잡는다.
    static func reference(for entry: LocalizationEntry, in table: LocalizationTable) -> String {
        if let source = entry.values[table.sourceLocale], !source.isEmpty { return source }
        return entry.values.sorted { $0.key < $1.key }.first { !$0.value.isEmpty }?.value ?? ""
    }

    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "super",
        "self", "Self", "throw", "throws", "true", "try", "Type", "Protocol",
    ]
}
