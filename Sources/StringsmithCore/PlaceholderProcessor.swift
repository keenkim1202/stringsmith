import Foundation

/// 테이블 전체의 변수 자리를 iOS 포맷으로 변환하고 검증한다.
///
/// 각 항목마다 **원문 로케일이 위치 번호를 정하고**, 번역은 이름으로 그 번호를 찾아간다.
/// 그래서 번역의 어순이 달라도 올바른 위치 지정자가 나온다.
public struct PlaceholderProcessor: Sendable {
    public let config: PlaceholderConfig
    let parser: PlaceholderParser
    let renderer: IOSFormatRenderer

    public init(config: PlaceholderConfig = PlaceholderConfig()) {
        self.config = config
        self.parser = PlaceholderParser(config: config)
        self.renderer = IOSFormatRenderer(config: config)
    }

    /// 값이 실제로 바뀐 기록. `--dry-run`과 리포트에 쓴다.
    public struct Conversion: Sendable, Equatable {
        public var key: String
        public var locale: String
        public var before: String
        public var after: String
    }

    public struct Issue: Sendable, Equatable {
        public enum Severity: String, Sendable { case error, warning }
        public var severity: Severity
        public var key: String
        public var locale: String?
        public var message: String
        public var row: Int

        public var formatted: String {
            let where_ = locale.map { "\(key) [\($0)]" } ?? key
            return "\(where_) (행 \(row)): \(message)"
        }
    }

    public struct Result: Sendable {
        public var table: LocalizationTable
        public var conversions: [Conversion]
        public var issues: [Issue]

        public var errors: [Issue] { issues.filter { $0.severity == .error } }
        public var warnings: [Issue] { issues.filter { $0.severity == .warning } }
    }

    public func process(_ table: LocalizationTable) -> Result {
        var entries: [LocalizationEntry] = []
        var conversions: [Conversion] = []
        var issues: [Issue] = []

        for entry in table.entries {
            var entry = entry
            guard let sourceValue = entry.values[table.sourceLocale] else {
                entries.append(entry)
                continue
            }

            // 원문은 위치표를 만들기 위해서만 파싱한다.
            // 표기 문제 보고는 아래 로케일 순회가 원문까지 함께 처리한다(중복 방지).
            let (sourceParsed, _) = parser.parse(sourceValue)
            let map = renderer.positionMap(for: sourceParsed)

            // V1c — 이름 없는 지정자가 2개 이상이면 어순 변화를 따라갈 수 없다.
            let unnamed = sourceParsed.placeholders.filter {
                $0.name == nil && $0.explicitPosition == nil
            }
            if unnamed.count >= 2 {
                issues.append(
                    Issue(
                        severity: .warning, key: entry.key, locale: table.sourceLocale,
                        message: tr(
                            """
                            \(unnamed.count) unnamed variables. If a translation reorders them \
                            there is no way to tell which is which. Prefer {name} notation.
                            """,
                            """
                            이름 없는 변수가 \(unnamed.count)개입니다. 번역에서 어순이 바뀌면 \
                            어느 자리인지 알 수 없습니다. {name} 표기를 권합니다.
                            """),
                        row: entry.sourceRow
                    ))
            }

            let sourceIdentities = Set(map.keys)

            for locale in entry.values.keys.sorted() {
                guard let raw = entry.values[locale] else { continue }
                let (parsed, findings) = parser.parse(raw)
                report(
                    findings: findings, key: entry.key, locale: locale,
                    row: entry.sourceRow, into: &issues
                )

                let identities = Set(parsed.placeholders.map(\.identity))

                // V1e — 원문에 없는 변수가 번역에만 있음
                let extra = identities.subtracting(sourceIdentities).sorted()
                if !extra.isEmpty {
                    issues.append(
                        Issue(
                            severity: .error, key: entry.key, locale: locale,
                            message: tr(
                                "Variables not in the source: \(extra.map { "{\($0)}" }.joined(separator: ", "))",
                                "원문에 없는 변수가 있습니다: \(extra.map { "{\($0)}" }.joined(separator: ", "))"),
                            row: entry.sourceRow
                        ))
                    continue
                }

                // V1a — 원문에 있는 변수가 번역에서 누락
                let missing = sourceIdentities.subtracting(identities).sorted()
                if !missing.isEmpty {
                    issues.append(
                        Issue(
                            severity: .error, key: entry.key, locale: locale,
                            message: tr(
                                "Missing variables: \(missing.map { "{\($0)}" }.joined(separator: ", "))",
                                "변수가 누락됐습니다: \(missing.map { "{\($0)}" }.joined(separator: ", "))"),
                            row: entry.sourceRow
                        ))
                    continue
                }

                guard let rendered = renderer.render(parsed, using: map) else {
                    issues.append(
                        Issue(
                            severity: .error, key: entry.key, locale: locale,
                            message: tr(
                                "Could not map the variables to positions.",
                                "변수를 위치 번호에 대응시키지 못했습니다."),
                            row: entry.sourceRow
                        ))
                    continue
                }

                if rendered != raw {
                    conversions.append(
                        Conversion(key: entry.key, locale: locale, before: raw, after: rendered))
                }
                entry.values[locale] = rendered
            }

            entries.append(entry)
        }

        return Result(
            table: LocalizationTable(sourceLocale: table.sourceLocale, entries: entries),
            conversions: conversions,
            issues: issues
        )
    }

    /// V1d — 변환할 수 없는 표기(인라인 마크업 등)를 경고로 남긴다.
    private func report(
        findings: PlaceholderParser.Findings,
        key: String, locale: String, row: Int,
        into issues: inout [Issue]
    ) {
        if !findings.unsupported.isEmpty {
            issues.append(
                Issue(
                    severity: .warning, key: key, locale: locale,
                    message: tr(
                        """
                        Left these tags alone — they are not variables: \
                        \(findings.unsupported.joined(separator: ", ")). \
                        Inline markup needs AttributedString on iOS.
                        """,
                        """
                        변수로 볼 수 없는 태그가 있어 그대로 두었습니다: \
                        \(findings.unsupported.joined(separator: ", ")). \
                        인라인 마크업은 iOS에서 AttributedString으로 따로 처리해야 합니다.
                        """),
                    row: row
                ))
        }

    }
}
