import Foundation

/// CLDR 복수 범주.
public enum PluralCategory: String, Sendable, CaseIterable, Comparable, Codable {
    case zero, one, two, few, many, other

    /// 사전 순이 아니라 CLDR 이 세는 순서로 정렬한다. 산출물이 읽기 좋아진다.
    public static func < (a: PluralCategory, b: PluralCategory) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// 로케일이 실제로 쓰는 복수 범주.
///
/// CLDR 전체를 싣지 않는다 — 표만 수백 줄이고, 이 도구가 다루는 건 사람이 시트에 적어 둔
/// 몇 개 언어다. **모르는 로케일은 `nil`** 을 돌려 아무 말도 하지 않는다. 틀린 경고를 내는
/// 것보다 조용한 편이 낫다.
public enum CLDR {

    static let table: [String: Set<PluralCategory>] = {
        var out: [String: Set<PluralCategory>] = [:]
        func put(_ categories: Set<PluralCategory>, _ locales: [String]) {
            for locale in locales { out[locale] = categories }
        }

        // 수를 세도 형태가 안 바뀌는 언어들.
        put(
            [.other],
            ["ko", "ja", "zh", "zh-Hans", "zh-Hant", "th", "vi", "id", "ms", "my", "km", "lo"])

        // 하나 / 그 밖에.
        put(
            [.one, .other],
            [
                "en", "de", "nl", "sv", "da", "nb", "no", "nn", "es", "it", "pt", "pt-BR",
                "fi", "et", "el", "he", "hu", "tr", "bg", "ca", "eu", "gl", "sw", "af",
                "sq", "az", "ka", "kk", "ky", "uz", "ta", "te", "ml", "mr", "ne", "si",
            ])

        // 프랑스어 계열은 0 도 단수로 센다. 범주 이름은 같다.
        put([.one, .many, .other], ["fr", "fr-CA"])

        // 슬라브어 계열.
        put([.one, .few, .many, .other], ["ru", "uk", "be", "pl", "cs", "sk", "hr", "sr", "bs", "lt"])
        put([.zero, .one, .other], ["lv"])

        // 아랍어는 여섯 개를 다 쓴다.
        put([.zero, .one, .two, .few, .many, .other], ["ar", "cy"])
        put([.one, .two, .few, .many, .other], ["ga", "gd"])

        // 힌디·페르시아 계열.
        put([.one, .other], ["hi", "bn", "gu", "fa", "ur"])
        return out
    }()

    /// 모르는 로케일이면 `nil`.
    public static func categories(for locale: String) -> Set<PluralCategory>? {
        if let exact = table[locale] { return exact }
        // `en-GB` → `en`. 지역 변형은 복수 규칙이 같다.
        let base = locale.split(separator: "-").first.map(String.init) ?? locale
        return table[base]
    }
}

// MARK: - 시트에서 복수형 묶기

/// 접미사가 같은 키들을 한 항목으로 본 것.
///
/// 시트에 복수형을 적는 방법은 **키 접미사**다 — `cart.items.one` · `cart.items.other`.
/// 열을 따로 두는 방법도 있지만, 그러면 언어마다 범주 수가 달라서(아랍어는 여섯 개)
/// 열이 계속 늘어난다. 접미사는 행만 늘어난다.
public struct PluralGroup: Sendable, Equatable {
    /// 접미사를 뗀 키. `cart.items`
    public var key: String
    /// 범주 → 그 범주의 행.
    public var variants: [PluralCategory: LocalizationEntry]

    /// 어느 행이든 하나. 오류 메시지의 위치로 쓴다.
    var anyEntry: LocalizationEntry? {
        variants.sorted { $0.key < $1.key }.first?.value
    }
}

public enum Plurals {

    /// 테이블을 복수형 묶음과 나머지로 가른다.
    ///
    /// 접미사가 하나뿐이면(`cart.items.other` 만 있고 다른 게 없으면) 묶지 않는다 — 우연히
    /// `.one` 으로 끝나는 평범한 키를 복수형으로 오해하지 않기 위해서다.
    public static func split(
        _ table: LocalizationTable
    ) -> (groups: [PluralGroup], singles: [LocalizationEntry]) {
        var byKey: [String: [PluralCategory: LocalizationEntry]] = [:]
        var order: [String] = []
        var singles: [LocalizationEntry] = []

        for entry in table.entries {
            guard let separator = entry.key.lastIndex(of: "."),
                let category = PluralCategory(
                    rawValue: String(entry.key[entry.key.index(after: separator)...]))
            else {
                singles.append(entry)
                continue
            }
            let base = String(entry.key[..<separator])
            if byKey[base] == nil { order.append(base) }
            byKey[base, default: [:]][category] = entry
        }

        var groups: [PluralGroup] = []
        for base in order {
            let variants = byKey[base]!
            guard variants.count > 1 else {
                // 접미사 하나짜리는 그냥 키다.
                singles.append(contentsOf: variants.values)
                continue
            }
            groups.append(PluralGroup(key: base, variants: variants))
        }
        return (groups, singles.sorted { $0.key < $1.key })
    }

    // MARK: - V6 검증

    /// 로케일이 쓰지 않는 범주, 빠뜨린 범주, 없는 `other` 를 짚는다.
    public static func problems(
        _ groups: [PluralGroup], locales: [String], sourceLocale: String
    ) -> [Warning] {
        var missingOther: [Warning.Item] = []
        var unused: [Warning.Item] = []
        var incomplete: [Warning.Item] = []

        for group in groups {
            guard let anchor = group.anyEntry else { continue }
            let item = { (note: String?) in
                Warning.Item(key: group.key, location: anchor.sourceLabel, note: note)
            }

            // CLDR 은 `other` 를 항상 요구한다. 없으면 iOS 가 표시할 게 없다.
            if group.variants[.other] == nil {
                missingOther.append(item(nil))
                continue
            }

            for locale in locales.sorted() {
                guard let expected = CLDR.categories(for: locale) else { continue }
                // 이 로케일에 실제로 값이 채워진 범주만 센다.
                let present = Set(
                    group.variants.filter { !($0.value.values[locale] ?? "").isEmpty }.keys)
                guard !present.isEmpty else { continue }

                let extra = present.subtracting(expected).sorted()
                if !extra.isEmpty {
                    unused.append(
                        item("\(locale) — \(extra.map(\.rawValue).joined(separator: ", "))"))
                }
                let lacking = expected.subtracting(present).sorted()
                if !lacking.isEmpty {
                    incomplete.append(
                        item("\(locale) — \(lacking.map(\.rawValue).joined(separator: ", "))"))
                }
            }
        }

        var warnings: [Warning] = []
        if !missingOther.isEmpty {
            warnings.append(
                Warning(
                    kind: .plural,
                    summary: tr(
                        "\(missingOther.count) plural key(s) have no \"other\" — CLDR requires it",
                        "\"other\" 가 없는 복수형 키 \(missingOther.count)개 — CLDR 이 요구합니다"),
                    items: missingOther))
        }
        if !unused.isEmpty {
            warnings.append(
                Warning(
                    kind: .plural,
                    summary: tr(
                        "\(unused.count) plural form(s) the locale never uses",
                        "그 언어가 쓰지 않는 복수형 \(unused.count)건"),
                    items: unused))
        }
        if !incomplete.isEmpty {
            warnings.append(
                Warning(
                    kind: .plural,
                    summary: tr(
                        "\(incomplete.count) plural form(s) the locale needs but the sheet lacks",
                        "그 언어에 필요한데 시트에 없는 복수형 \(incomplete.count)건"),
                    items: incomplete))
        }
        _ = sourceLocale
        return warnings
    }
}
