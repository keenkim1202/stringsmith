import Foundation

/// 이미 있는 로컬라이제이션 파일에서 시트 초안을 만든다.
///
/// 이게 없으면 stringsmith 는 새 프로젝트 전용이다. 문자열이 이미 300개 있는 앱은 시트를
/// 손으로 옮겨 적어야 하고, 대부분 거기서 도입이 끝난다.
///
/// 산출물은 CSV 한 장이다. 설정까지 여기서 만들지 않는 건 `ss init` 이 이미 헤더를 보고
/// 그 일을 하기 때문이다.
public enum LocalizationImport {

    /// 읽어들인 항목 하나. 시트의 한 행이 된다.
    struct Item {
        var key: String
        var comment: String?
        var values: [String: String]
        /// 복수형 변형인가. 수를 세는 변수의 이름이 달라진다.
        var isPlural = false
    }

    public struct Result: Sendable {
        /// 헤더를 포함한 CSV 행.
        public var rows: [[String]]
        public var sourceLocale: String
        public var locales: [String]
        public var keyCount: Int
        /// 변수가 들어 있어 이름을 손봐야 하는 키.
        public var needsNaming: [String]
        /// 옮기지 못한 것. 이유를 함께 담는다.
        public var skipped: [String]
    }

    // MARK: - 입구

    /// - Parameters:
    ///   - path: `.xcstrings` 파일, 또는 `.lproj` 들을 담은 디렉터리.
    ///   - sourceLocale: 원문 로케일. `.xcstrings` 는 파일이 알고 있으므로 무시한다.
    ///   - table: 읽을 `.strings` 테이블 이름. `.xcstrings` 에는 해당하지 않는다.
    public static func read(
        path: String, sourceLocale: String? = nil, table: String = defaultTable
    ) throws -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw StringsmithError.io(
                path: path, reason: tr("No such file or directory.", "그런 파일이나 디렉터리가 없습니다."))
        }

        if !isDirectory.boolValue {
            return try importCatalog(at: path)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        if contents.contains(where: { $0.hasSuffix(".lproj") }) {
            return try importLproj(in: path, sourceLocale: sourceLocale, table: table)
        }
        let catalogs = contents.filter { $0.hasSuffix(".xcstrings") }
        if catalogs.count == 1 {
            return try importCatalog(at: (path as NSString).appendingPathComponent(catalogs[0]))
        }
        throw StringsmithError.io(
            path: path,
            reason: catalogs.count > 1
                ? tr(
                    "More than one .xcstrings here: \(catalogs.sorted().joined(separator: ", ")). Point at one.",
                    ".xcstrings 가 여럿입니다: \(catalogs.sorted().joined(separator: ", ")). 하나를 지정하세요.")
                : tr(
                    "Found no .xcstrings and no .lproj directories.",
                    ".xcstrings 도 .lproj 디렉터리도 없습니다."))
    }

    // MARK: - String Catalog

    static func importCatalog(at path: String) throws -> Result {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StringsmithError.io(path: path, reason: tr("Could not read the file.", "파일을 읽을 수 없습니다."))
        }
        let document: XCStringsDocument
        do {
            document = try JSONDecoder().decode(XCStringsDocument.self, from: data)
        } catch {
            throw StringsmithError.io(
                path: path,
                reason: tr(
                    "Not a String Catalog: \(error.localizedDescription)",
                    "String Catalog 이 아닙니다: \(error.localizedDescription)"))
        }

        var items: [Item] = []
        var skipped: [String] = []

        for (key, entry) in document.strings {
            var plain: [String: String] = [:]
            var byCategory: [PluralCategory: [String: String]] = [:]
            // 이 키에 대해 이미 무언가 짚었는가. 같은 사실을 두 번 말하지 않으려고 본다.
            var noted = false

            for (locale, localization) in entry.localizations ?? [:] {
                if let unit = localization.stringUnit {
                    plain[locale] = unit.value
                } else if let plural = localization.variations?.plural {
                    for (name, nested) in plural {
                        guard let category = PluralCategory(rawValue: name) else {
                            // CLDR 밖의 범주는 시트의 키 접미사로 적을 수 없다.
                            skipped.append(tr(
                                "\(key) [\(locale)]: unknown plural category \"\(name)\"",
                                "\(key) [\(locale)]: 모르는 복수 범주 \"\(name)\""))
                            noted = true
                            continue
                        }
                        guard let value = nested.stringUnit?.value else { continue }
                        byCategory[category, default: [:]][locale] = value
                    }
                } else if localization.variations != nil {
                    // 기기별 변형(`device`). 시트는 한 키에 값 하나라 담을 자리가 없다.
                    skipped.append(tr(
                        "\(key) [\(locale)]: a variation this tool does not read (device?)",
                        "\(key) [\(locale)]: 이 도구가 읽지 않는 변형입니다 (기기별?)"))
                    noted = true
                }
            }

            if !plain.isEmpty {
                items.append(Item(key: key, comment: entry.comment, values: plain))
            }
            // 복수형은 시트에서 키 접미사로 적힌다. `cart.items` 하나가 여러 행이 된다.
            for (category, values) in byCategory {
                items.append(
                    Item(
                        key: "\(key).\(category.rawValue)", comment: entry.comment,
                        values: values, isPlural: true))
            }
            // 이미 짚었으면 또 말하지 않는다. 같은 사실이다. 다만 **아무 말도 없이**
            // 키가 사라지는 일은 없어야 한다. 없어진 걸 아무도 모르는 게 제일 나쁘다.
            //
            // localizations 가 비었는지로 판단하면 안 된다. 값이 들어 있는데 우리가 못 읽는
            // 모양(빈 로케일 객체, 범주 안에 또 변형이 든 것)이 그 검사를 통과해 버린다.
            if plain.isEmpty, byCategory.isEmpty, !noted {
                skipped.append(
                    entry.localizations?.isEmpty ?? true
                        ? tr("\(key): no translations", "\(key): 번역이 없습니다")
                        : tr(
                            "\(key): nothing here this tool could read",
                            "\(key): 읽을 수 있는 내용이 없습니다"))
            }
        }

        return assemble(items, sourceLocale: document.sourceLanguage, skipped: skipped)
    }

    // MARK: - .lproj

    static func importLproj(
        in directory: String, sourceLocale: String?, table: String = defaultTable
    ) throws -> Result {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".lproj") }
            .sorted()

        var byKey: [String: Item] = [:]
        var skipped: [String] = []
        var locales: [String] = []
        // 옮기지 않은 테이블. 로케일마다 같은 이름이 반복되므로 한 번만 알린다.
        var otherTables: Set<String> = []

        for name in names {
            let locale = String(name.dropLast(".lproj".count))
            // Base.lproj 는 로케일이 아니다. 스토리보드용 원문이 들어가는 자리다.
            guard locale != "Base" else {
                skipped.append(tr("Base.lproj (not a locale)", "Base.lproj (로케일이 아닙니다)"))
                continue
            }
            locales.append(locale)
            let folder = (directory as NSString).appendingPathComponent(name)

            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                guard let other = tableName(of: name), other != table else { continue }
                otherTables.insert(other)
            }

            let comments = readComments(in: folder, table: table)
            for (key, value) in readStrings(in: folder, table: table, skipped: &skipped) {
                byKey[key, default: Item(key: key, comment: nil, values: [:])].values[locale] = value
                // 주석은 로케일마다 같은 내용이 반복된다. 먼저 본 것을 쓴다.
                if byKey[key]?.comment == nil { byKey[key]?.comment = comments[key] }
            }
            for (key, value) in readStringsdict(
                in: folder, table: table, locale: locale, skipped: &skipped)
            {
                byKey[key, default: Item(key: key, comment: nil, values: [:], isPlural: true)]
                    .values[locale] = value
            }
        }

        guard !locales.isEmpty else {
            throw StringsmithError.io(
                path: directory,
                reason: tr("No .lproj directories to read.", "읽을 .lproj 디렉터리가 없습니다."))
        }

        // 말없이 절반만 옮기면 없어진 걸 아무도 모른다. 이름을 대고 --table 을 알린다.
        for name in otherTables.sorted() {
            // 파일 이름을 대지 않는다. 테이블은 `.strings` 로도 `.stringsdict` 로도
            // 존재할 수 있어서, 하나를 골라 적으면 없는 파일을 가리키게 된다.
            skipped.append(tr(
                "table \"\(name)\": not read (--table \(name) reads it instead)",
                "테이블 \"\(name)\": 읽지 않았습니다 (--table \(name) 로 읽습니다)"))
        }

        // 원문 로케일은 파일이 말해 주지 않는다. 지정이 없으면 en, 그것도 없으면 첫 번째.
        let source = sourceLocale ?? (locales.contains("en") ? "en" : locales.sorted()[0])
        return assemble(Array(byKey.values), sourceLocale: source, skipped: skipped)
    }

    /// 파일 이름에서 테이블 이름을 뽑는다. 로컬라이제이션 파일이 아니면 nil.
    ///
    /// `.stringsdict` 까지 보는 이유는, 복수형만 담은 테이블은 짝이 되는 `.strings` 없이
    /// `.stringsdict` 하나로 존재하기 때문이다. `.strings` 만 훑으면 그런 테이블은
    /// 통째로 빠지고 아무도 그 사실을 모른다.
    static func tableName(of file: String) -> String? {
        for suffix in [".stringsdict", ".strings"] where file.hasSuffix(suffix) {
            return String(file.dropLast(suffix.count))
        }
        return nil
    }

    /// `<table>.strings`. 구식 property list 라서 Foundation 이 그대로 읽는다.
    static func readStrings(
        in folder: String, table: String, skipped: inout [String]
    ) -> [String: String] {
        let path = (folder as NSString).appendingPathComponent("\(table).strings")
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let table = plist as? [String: String]
        else {
            skipped.append(tr("\(path): could not be parsed", "\(path): 해석하지 못했습니다"))
            return [:]
        }
        return table
    }

    /// `.strings` 의 `/* ... */` 주석. 번역가가 읽는 설명이라 옮기지 않으면 그냥 사라진다.
    ///
    /// 값은 `PropertyListSerialization` 이 읽는다. 그쪽은 주석을 버리므로 원문을 한 번 더
    /// 훑는다. 못 찾으면 주석이 없는 것으로 둔다. 값을 잘못 읽을 여지는 없다.
    static func readComments(in folder: String, table: String) -> [String: String] {
        let path = (folder as NSString).appendingPathComponent("\(table).strings")
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return [:] }

        let pattern = #"/\*(.*?)\*/\s*"((?:[^"\\]|\\.)*)"\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [:] }

        var out: [String: String] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            guard let comment = Range(match.range(at: 1), in: text),
                let key = Range(match.range(at: 2), in: text)
            else { continue }
            let trimmed = text[comment].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out[unescape(String(text[key]))] = trimmed
        }
        return out
    }

    /// `.strings` 키에 남은 이스케이프를 되돌린다. 값 쪽은 plist 파서가 이미 해 준다.
    static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// `<table>.stringsdict`. 범주 하나가 시트의 한 행(`key.one`)이 된다.
    static func readStringsdict(
        in folder: String, table: String, locale: String, skipped: inout [String]
    ) -> [String: String] {
        let path = (folder as NSString).appendingPathComponent("\(table).stringsdict")
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let table = plist as? [String: Any]
        else {
            skipped.append(tr("\(path): could not be parsed", "\(path): 해석하지 못했습니다"))
            return [:]
        }

        var out: [String: String] = [:]
        for (key, raw) in table {
            guard let entry = raw as? [String: Any],
                let format = entry["NSStringLocalizedFormatKey"] as? String
            else { continue }

            // 형식 문자열이 가리키는 변수 이름들. `You have %#@count@ left` → ["count"]
            let variables = formatVariables(in: format)
            guard variables.count == 1, let variable = variables.first,
                let spec = entry[variable] as? [String: Any]
            else {
                // 변수가 둘 이상이면 범주 조합이 곱해진다. 시트의 접미사 한 줄로는 못 적는다.
                skipped.append(tr(
                    "\(key) [\(locale)]: \(variables.count) plural variables in one string",
                    "\(key) [\(locale)]: 한 문자열에 복수형 변수가 \(variables.count)개"))
                continue
            }

            for category in PluralCategory.allCases {
                guard let value = spec[category.rawValue] as? String else { continue }
                // 형식 문자열에 앞뒤 문장이 붙어 있으면 그것까지 살려야 뜻이 온전하다.
                out["\(key).\(category.rawValue)"] =
                    format.replacingOccurrences(of: "%#@\(variable)@", with: value)
            }
        }
        return out
    }

    /// `%#@name@` 에서 이름만 뽑는다.
    static func formatVariables(in format: String) -> [String] {
        var out: [String] = []
        var rest = Substring(format)
        while let start = rest.range(of: "%#@") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "@") else { break }
            out.append(String(after[..<end]))
            rest = after[after.index(after: end)...]
        }
        return out
    }

    // MARK: - 시트로

    static func assemble(_ items: [Item], sourceLocale: String, skipped: [String]) -> Result {
        var needsNaming: [String] = []
        var converted: [Item] = []
        var skipped = skipped

        for var item in items {
            // 카탈로그의 named substitution(`%#@count@`). 시트는 한 칸에 문자열 하나라
            // 이 구조를 담을 수 없다. 그냥 두면 파서가 `%#` 를 플래그로 읽어
            // `{arg1}count@` 같은 그럴듯한 쓰레기를 만들고, 그건 아무도 못 찾는다.
            if item.values.values.contains(where: { $0.contains("%#@") }) {
                skipped.append(tr(
                    "\(item.key): uses %#@…@ substitutions, which a sheet cannot hold",
                    "\(item.key): %#@…@ 치환을 씁니다. 시트로는 담을 수 없는 구조입니다"))
                continue
            }
            var touched = false
            for (locale, value) in item.values {
                let (rewritten, hadPlaceholder) = convertPlaceholders(
                    value, countVariable: item.isPlural ? Self.countVariable : nil)
                item.values[locale] = rewritten
                touched = touched || hadPlaceholder
            }
            if touched { needsNaming.append(item.key) }
            converted.append(item)
        }

        let locales = Set(converted.flatMap(\.values.keys))
        // 원문이 먼저, 나머지는 사전 순. 시트를 여는 사람은 원문부터 본다.
        let ordered = [sourceLocale] + locales.subtracting([sourceLocale]).sorted()
        let hasComments = converted.contains { !($0.comment ?? "").isEmpty }

        var header = ["key"]
        if hasComments { header.append("description") }
        header += ordered

        var rows = [header]
        for item in converted.sorted(by: { $0.key < $1.key }) {
            var row = [item.key]
            if hasComments { row.append(item.comment ?? "") }
            row += ordered.map { item.values[$0] ?? "" }
            rows.append(row)
        }

        return Result(
            rows: rows,
            sourceLocale: sourceLocale,
            locales: ordered,
            keyCount: converted.count,
            needsNaming: needsNaming.sorted(),
            skipped: skipped.sorted())
    }

    // MARK: - 변수

    /// 파일에 있는 `%@` 표기를 시트의 `{name}` 표기로 바꾼다.
    ///
    /// **이름은 되살릴 수 없다.** 파일에는 자리와 순서만 남아 있고, 그 자리가 무엇이었는지는
    /// 호출하는 코드에만 있다. `{arg1}` 로 두고 사람이 고치게 한다. 여기서 추측하면 틀린
    /// 이름이 시트에 박히고, 그건 아무것도 안 한 것보다 나쁘다.
    ///
    /// - Returns: 바꾼 값과, 변수가 하나라도 있었는지.
    static func convertPlaceholders(
        _ value: String, countVariable: String? = nil
    ) -> (String, Bool) {
        let (parsed, _) = parser.parse(value)
        guard !parsed.placeholders.isEmpty else { return (escaped(value), false) }

        var out = ""
        var namedCount = false
        for segment in parsed.segments {
            switch segment {
            case let .text(text):
                out += escaped(text)
            case let .placeholder(placeholder):
                // 복수형에서 수를 세는 변수만은 이름이 중요하다. 생성기는 이 이름을 보고
                // `%d` 를 내보내는데, `.stringsdict` 의 NSStringPluralRuleType 은 정수를
                // 봐야 어느 범주인지 고를 수 있다. `%@` 가 되면 런타임에 복수형이 깨진다.
                if let countVariable, !namedCount, isInteger(placeholder.conversion) {
                    out += "{\(countVariable)}"
                    namedCount = true
                    continue
                }
                // 위치 지정자(`%2$@`)가 있으면 그 번호를 쓴다. 어순이 다른 번역끼리
                // 같은 이름으로 이어지려면 번호가 같아야 한다.
                out += "{arg\(placeholder.explicitPosition ?? placeholder.ordinal + 1)}"
            }
        }
        return (out, true)
    }

    /// 정수 지정자인가. 길이 수식어(`%lld`)는 파서가 이미 떼어 낸다.
    static func isInteger(_ conversion: Character?) -> Bool {
        guard let conversion else { return false }
        return "dDuUxX".contains(conversion)
    }

    /// 수를 세는 변수의 이름. `output.pluralVariable` 의 기본값과 같아야 한다.
    static let countVariable = "count"

    /// 기본 테이블 이름. `output.tableName` 의 기본값과 같다.
    public static let defaultTable = "Localizable"

    /// 원문에 있던 중괄호가 변수로 읽히지 않게 한다.
    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
    }

    /// `%@`·`%1$@`·`%d` 만 본다. 파일에 `{name}` 이 있으면 그건 그냥 글자다.
    static let parser = PlaceholderParser(config: PlaceholderConfig(syntax: ["apple"]))
}
