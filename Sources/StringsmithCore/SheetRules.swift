import Foundation

/// 변수 표기와 무관한, 시트 자체에 대한 규칙들.
///
/// 전부 경고다. 여기서 걸리는 것들은 "틀렸다" 기보다 "그러려던 게 맞나" 에 가깝고,
/// 실제로 의도한 경우가 있다. 막을지 말지는 `validation.failOn` 이 정한다.
public enum SheetRules {

    // MARK: - V3 키 이름

    /// 키가 만들 수 없는 이름이거나, 정한 규칙을 벗어난 것.
    ///
    /// 명명 스타일을 강요하지는 않는다 — 팀마다 `screen.key` 도 쓰고 `screenKey` 도 쓴다.
    /// 기본으로 보는 건 **어느 스타일이든 문제가 되는 것**뿐이고, 규칙을 강제하고 싶으면
    /// `validation.keyPattern` 에 정규식을 준다.
    public static func keyProblems(_ entries: [LocalizationEntry], pattern: String?) -> [Warning] {
        var malformed: [Warning.Item] = []
        var offPattern: [Warning.Item] = []

        let expression = pattern.flatMap { try? NSRegularExpression(pattern: $0) }

        for entry in entries {
            let key = entry.key
            let item = Warning.Item(key: key, location: entry.sourceLabel)

            // 공백이 든 키는 거의 언제나 복사하다 딸려 온 것이다. 눈으로는 안 보인다.
            let hasSpace = key.contains { $0.isWhitespace }
            // 빈 조각이 생기는 점 — `a..b`·`.a`·`a.` 는 네임스페이스가 이상하게 잘린다.
            let brokenDots =
                key.hasPrefix(".") || key.hasSuffix(".") || key.contains("..")

            if hasSpace || brokenDots {
                malformed.append(item)
                continue
            }

            if let expression {
                let range = NSRange(key.startIndex..<key.endIndex, in: key)
                if expression.firstMatch(in: key, range: range) == nil {
                    offPattern.append(item)
                }
            }
        }

        var warnings: [Warning] = []
        if !malformed.isEmpty {
            warnings.append(
                Warning(
                    kind: .key,
                    summary: tr(
                        "\(malformed.count) key(s) contain spaces or stray dots",
                        "공백이나 잘못된 점이 든 키 \(malformed.count)개"),
                    items: malformed))
        }
        if !offPattern.isEmpty, let pattern {
            warnings.append(
                Warning(
                    kind: .key,
                    summary: tr(
                        "\(offPattern.count) key(s) do not match \(pattern)",
                        "\(pattern) 에 맞지 않는 키 \(offPattern.count)개"),
                    items: offPattern))
        }
        return warnings
    }

    // MARK: - V8 눈에 안 보이는 문자

    /// 붙여넣다 딸려 오는 문자들.
    ///
    /// 폭 0 접합자(U+200D)는 **일부러 뺐다** — 👨‍👩‍👧‍👦 같은 결합 이모지가 이걸로 이어져 있어서,
    /// 넣으면 멀쩡한 값이 무더기로 걸린다. 방향 표시 문자(U+200E·U+200F)도 뺐다. 아랍어와
    /// 라틴 문자를 섞을 때 실제로 필요하다.
    static let invisibles: [(scalar: Unicode.Scalar, name: String)] = [
        (Unicode.Scalar(0x00A0)!, "no-break space"),
        (Unicode.Scalar(0x200B)!, "zero-width space"),
        (Unicode.Scalar(0x200C)!, "zero-width non-joiner"),
        (Unicode.Scalar(0xFEFF)!, "byte-order mark"),
    ]

    /// 눈에 보이지 않아 검색으로도 안 잡히는 문자와, 앞뒤 공백.
    ///
    /// 앞뒤 공백을 지우지 않기로 했으니(`Pipeline` translation()) 대신 짚어는 준다.
    /// `"{name} "` 처럼 일부러 둔 경우가 있어 고치지는 않는다.
    public static func invisibleCharacters(_ entries: [LocalizationEntry]) -> [Warning] {
        var hidden: [Warning.Item] = []
        var padded: [Warning.Item] = []

        for entry in entries {
            for (locale, value) in entry.values.sorted(by: { $0.key < $1.key }) {
                let found = invisibles.filter { value.unicodeScalars.contains($0.scalar) }
                if !found.isEmpty {
                    hidden.append(
                        Warning.Item(
                            key: entry.key, location: entry.sourceLabel,
                            note: "\(locale) — \(found.map(\.name).joined(separator: ", "))"))
                }
                if value != value.trimmingCharacters(in: .whitespaces) {
                    padded.append(
                        Warning.Item(key: entry.key, location: entry.sourceLabel, note: locale))
                }
            }
        }

        var warnings: [Warning] = []
        if !hidden.isEmpty {
            warnings.append(
                Warning(
                    kind: .whitespace,
                    summary: tr(
                        "\(hidden.count) value(s) contain invisible characters",
                        "눈에 보이지 않는 문자가 든 값 \(hidden.count)건"),
                    items: hidden))
        }
        if !padded.isEmpty {
            warnings.append(
                Warning(
                    kind: .whitespace,
                    summary: tr(
                        "\(padded.count) value(s) have leading or trailing spaces (kept as-is)",
                        "앞뒤 공백이 있는 값 \(padded.count)건 (그대로 둡니다)"),
                    items: padded))
        }
        return warnings
    }

    // MARK: - V7 길이

    /// 원문에 비해 유난히 긴 번역.
    ///
    /// **고정 배수를 쓰지 않는다.** 한국어 원문에서 영어로 가면 글자 수가 원래 두 배쯤 되고,
    /// 일본어로 가면 비슷하다. 1.8배 같은 값을 그대로 걸면 영어 열 전체가 걸려서 아무도 안 본다.
    /// 대신 **그 로케일의 중앙값 대비** 몇 배인지를 본다 — 한 언어 안에서 유독 튀는 항목만 남는다.
    ///
    /// - Parameter factor: 중앙값의 몇 배부터 볼지. `0` 이면 끈다.
    public static func lengthOutliers(
        _ table: LocalizationTable, factor: Double
    ) -> [Warning] {
        guard factor > 0 else { return [] }
        let source = table.sourceLocale
        var warnings: [Warning] = []

        for locale in table.locales.sorted() where locale != source {
            // 짧은 문구는 비율이 크게 흔들린다 ("네" → "Yes" 만 해도 1.5배다).
            let measured: [(entry: LocalizationEntry, ratio: Double)] =
                table.entries.compactMap { entry in
                    guard let origin = entry.values[source], origin.count >= 8,
                        let translated = entry.values[locale], !translated.isEmpty
                    else { return nil }
                    return (entry, Double(translated.count) / Double(origin.count))
                }
            // 중앙값을 믿으려면 표본이 좀 있어야 한다.
            guard measured.count >= 8 else { continue }

            let sorted = measured.map(\.ratio).sorted()
            let median = sorted[sorted.count / 2]
            let limit = median * factor

            let outliers = measured.filter { $0.ratio > limit }
            guard !outliers.isEmpty else { continue }

            warnings.append(
                Warning(
                    kind: .length,
                    summary: tr(
                        "\(locale): \(outliers.count) translation(s) much longer than usual "
                            + "(over \(String(format: "%.1f", limit))× the source)",
                        "\(locale): 유난히 긴 번역 \(outliers.count)건 "
                            + "(원문의 \(String(format: "%.1f", limit))배 초과)"),
                    items: outliers.map {
                        Warning.Item(
                            key: $0.entry.key, location: $0.entry.sourceLabel,
                            note: tr(
                                "\(locale), \(String(format: "%.1f", $0.ratio))×",
                                "\(locale), \(String(format: "%.1f", $0.ratio))배"))
                    }))
        }
        return warnings
    }
}
