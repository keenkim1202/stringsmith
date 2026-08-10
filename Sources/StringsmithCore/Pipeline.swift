import Foundation

/// 시트 → 검증 → 산출물의 전체 흐름.
///
/// 코어는 자료구조만 돌려준다. 출력·프린트는 CLI가 담당한다.
public struct Pipeline: Sendable {
    public let configuration: Configuration
    /// 설정의 상대 경로를 푸는 기준 디렉터리.
    public let baseDirectory: String
    /// 설정의 `output.artifacts`를 이번 실행에만 덮어쓴다.
    public let only: [String]?

    public init(configuration: Configuration, baseDirectory: String, only: [String]? = nil) {
        self.configuration = configuration
        self.baseDirectory = baseDirectory
        self.only = only
    }

    /// 내용이 같으면 쓰지 않는다. mtime 을 건드리면 불필요한 재빌드가 난다.
    static func writeIfChanged(_ data: Data, to path: String) throws -> Bool {
        if FileManager.default.contents(atPath: path) == data { return false }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw StringsmithError.io(path: directory, reason: tr("Could not create the directory.", "디렉터리를 만들 수 없습니다."))
            }
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw StringsmithError.io(path: path, reason: error.localizedDescription)
        }
        return true
    }

    // MARK: - 읽기

    /// 설정이 가리키는 시트 소스를 만든다.
    public func makeSource() throws -> SheetSource {
        switch configuration.source.type {
        case "google-sheets":
            guard let url = configuration.source.url, !url.isEmpty else {
                throw StringsmithError.invalidConfiguration(
                    path: configuration.source.path,
                    reason: tr(
                        "source.type is \"google-sheets\" but source.url is missing.",
                        "source.type 이 \"google-sheets\" 인데 source.url 이 없습니다."))
            }
            return GoogleSheetsSource(
                url: url,
                gid: configuration.source.gid,
                tabs: configuration.source.tabs ?? [],
                headerRow: configuration.source.headerRow,
                // 네트워크가 안 될 때 쓸 마지막 사본. 생성물이 아니므로 .stringsmith 아래 둔다.
                cachePath: resolve(".stringsmith/cache/sheet.csv"),
                // 로그인되어 있으면 Sheets API 로, 아니면 공개 링크로 읽는다.
                tokens: FileTokenStore()
            )
        default:
            return LocalFileSource(path: resolve(configuration.source.path))
        }
    }

    /// 시트를 읽어 테이블을 만든다. 검증 실패는 여기서 던진다.
    public func loadTable() throws -> LocalizationTable {
        let source = try makeSource()
        let path = configuration.source.url ?? resolve(configuration.source.path)
        let rows = try source.rows()

        guard !rows.isEmpty else {
            throw StringsmithError.emptySheet(path: path)
        }
        let headerRow = configuration.source.headerRow
        guard headerRow >= 1, headerRow <= rows.count else {
            throw StringsmithError.headerRowOutOfRange(requested: headerRow, totalRows: rows.count)
        }

        let index = HeaderIndex(headers: rows[headerRow - 1])
        let mapping = configuration.columns

        let keyIndex = try index.index(of: mapping.key, role: "key")
        let screenIndex = try mapping.screen.map { try index.index(of: $0, role: "screen") }
        let descriptionIndex = try mapping.description.map {
            try index.index(of: $0, role: "description")
        }
        // 로케일 순서를 고정해 오류 메시지와 산출물이 실행마다 흔들리지 않게 한다.
        var languageIndices: [(locale: String, column: Int)] = []
        for locale in mapping.languages.keys.sorted() {
            let column = mapping.languages[locale]!
            languageIndices.append((locale, try index.index(of: column, role: "languages.\(locale)")))
        }

        /// 키·화면·설명처럼 **식별과 주석에 쓰이는** 칸. 앞뒤 공백은 실수이므로 다듬는다.
        func cell(_ row: [String], _ i: Int?) -> String? {
            guard let i, i < row.count else { return nil }
            let value = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        /// 번역 값이 들어가는 칸. **다듬지 않는다.**
        ///
        /// 앞뒤 공백이 의도된 경우가 실제로 있다 — `"{name} "` 처럼 뒤에 공백을 두고 다른
        /// 요소와 이어 붙이는 문구가 그렇다. 지워 버리면 시트에서 표현할 방법이 없어진다.
        ///
        /// 다만 **있는지 없는지는 다듬어서 판단한다.** 공백만 있는 칸은 번역이 아니라 빈 칸이고,
        /// 그걸 값으로 받으면 미번역 경고가 뜨지 않아 빠진 번역을 놓치게 된다.
        func translation(_ row: [String], _ i: Int?) -> String? {
            guard let i, i < row.count else { return nil }
            let value = row[i]
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

        var entries: [LocalizationEntry] = []
        var seen: [String: [Int]] = [:]

        for offset in headerRow..<rows.count {
            let row = rows[offset]
            let sheetRow = offset + 1  // 1-based 시트 행 번호

            // 완전히 빈 행은 조용히 건너뛴다. 실무 시트에는 늘 섞여 있다.
            let isBlank = !row.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if isBlank { continue }

            guard let key = cell(row, keyIndex) else { continue }

            var values: [String: String] = [:]
            for (locale, column) in languageIndices {
                if let value = translation(row, column) { values[locale] = value }
            }

            entries.append(
                LocalizationEntry(
                    key: key,
                    screen: cell(row, screenIndex),
                    comment: cell(row, descriptionIndex),
                    values: values,
                    sourceRow: sheetRow
                )
            )
            seen[key, default: []].append(sheetRow)
        }

        // V2 — 키 중복
        if let duplicate = seen.filter({ $0.value.count > 1 }).min(by: { $0.key < $1.key }) {
            throw StringsmithError.duplicateKey(key: duplicate.key, rows: duplicate.value.sorted())
        }

        // V4 — 원문 값 누락
        let sourceLocale = configuration.source.defaultLocale
        for entry in entries where (entry.values[sourceLocale] ?? "").isEmpty {
            throw StringsmithError.emptySourceValue(
                key: entry.key, locale: sourceLocale, row: entry.sourceRow
            )
        }

        return LocalizationTable(sourceLocale: sourceLocale, entries: entries)
    }

    // MARK: - 쓰기

    public struct BuildResult: Sendable {
        public var table: LocalizationTable
        /// 실제로 내용이 바뀌어 쓰인 경로.
        public var written: [String]
        /// 이미 동일해서 건드리지 않은 경로.
        public var unchanged: [String]
        /// 치명적이지 않은 문제. CLI가 사람에게 보여준다.
        public var warnings: [String]
        /// 변수 표기가 iOS 포맷으로 바뀐 기록. 말없이 고치지 않기 위해 항상 돌려준다.
        public var conversions: [PlaceholderProcessor.Conversion]
    }

    /// 이번 실행에서 만들 산출물. `only`가 주어지면 설정을 덮어쓴다.
    var artifacts: [String] { only ?? configuration.output.artifacts }

    /// 산출물을 만든다. `dryRun`이면 파일을 쓰지 않고 결과만 계산한다.
    public func build(dryRun: Bool = false) throws -> BuildResult {
        let raw = try loadTable()
        var written: [String] = []
        var unchanged: [String] = []
        var warnings: [String] = []

        // 변수 자리를 iOS 포맷으로 변환한다. 오류는 모아서 한 번에 던진다.
        let processed = PlaceholderProcessor(config: configuration.placeholders).process(raw)
        if !processed.errors.isEmpty {
            throw StringsmithError.validationFailed(issues: processed.errors.map(\.formatted))
        }
        warnings.append(contentsOf: processed.warnings.map(\.formatted))
        let table = processed.table

        // V5 — 번역 누락 (경고)
        let sourceLocale = table.sourceLocale
        for locale in table.locales where locale != sourceLocale {
            let missing = table.entries.filter { ($0.values[locale] ?? "").isEmpty }
            if !missing.isEmpty {
                let examples = missing.prefix(3).map(\.key).joined(separator: ", ")
                warnings.append(
                    tr(
                        "\(locale): \(missing.count)/\(table.entries.count) translations missing",
                        "\(locale): 번역 \(missing.count)/\(table.entries.count)건 누락")
                        + tr(" (e.g. \(examples))", " (예: \(examples))")
                )
            }
        }

        for artifact in artifacts {
            switch artifact {
            case "swift":
                let codegen = SwiftCodegen(
                    options: configuration.output.swift,
                    tableName: configuration.output.tableName
                )
                let result = codegen.generate(table: table)
                for collision in result.collisions {
                    warnings.append(
                        tr(
                            "Name collision, suffixed: \(collision)",
                            "Swift 이름 충돌로 접미사를 붙였습니다: \(collision)"))
                }
                let path = resolve(
                    configuration.output.path + "/" + configuration.output.swift.enumName + ".swift"
                )
                let data = Data(result.source.utf8)
                if dryRun {
                    if FileManager.default.contents(atPath: path) == data {
                        unchanged.append(path)
                    } else {
                        written.append(path)
                    }
                } else if try Self.writeIfChanged(data, to: path) {
                    written.append(path)
                } else {
                    unchanged.append(path)
                }

            case "xcstrings":
                let path = resolve(
                    configuration.output.path + "/" + configuration.output.tableName + ".xcstrings"
                )
                let document = XCStringsDocument(table: table)
                if dryRun {
                    let data = try XCStringsWriter.data(for: document)
                    if FileManager.default.contents(atPath: path) == data {
                        unchanged.append(path)
                    } else {
                        written.append(path)
                    }
                } else if try XCStringsWriter.write(document, to: path) {
                    written.append(path)
                } else {
                    unchanged.append(path)
                }

            default:
                warnings.append(
                    tr(
                        "Skipping unknown artifact \"\(artifact)\".",
                        "알 수 없는 산출물 \"\(artifact)\" 는 건너뜁니다."))
            }
        }

        return BuildResult(
            table: table, written: written, unchanged: unchanged,
            warnings: warnings, conversions: processed.conversions
        )
    }

    // MARK: - 경로

    func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (baseDirectory as NSString).appendingPathComponent(path)
    }
}
