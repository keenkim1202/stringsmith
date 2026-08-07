import ArgumentParser
import Foundation
import StringsmithCore

@main
struct Stringsmith: ParsableCommand {
    /// 파이프로 내보낼 때 stdout 은 블록 버퍼링이라 stderr 로 나가는 오류보다 늦게 보인다.
    /// 진행 메시지와 오류의 순서가 뒤집히면 읽는 사람이 혼란스러우므로 줄 단위로 흘린다.
    static func configureBuffering() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    static let configuration = CommandConfiguration(
        commandName: "stringsmith",
        abstract: tr(
            "Generate iOS localization files from a spreadsheet.",
            "스프레드시트에서 iOS 로컬라이제이션 파일을 만듭니다."),
        discussion: tr(
            """
            Getting started:
              stringsmith init          write a config
              stringsmith generate      write the artifacts
              stringsmith preview       open the review app

            'ss' is a short alias for 'stringsmith' — 'ss generate' is the same
            command. 'make install' creates it; for a downloaded binary, make it
            yourself:
              ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss

            Input is a CSV/TSV file or a Google Sheets URL. XLSX comes later.
            """,
            """
            시작하기:
              stringsmith init          설정을 만듭니다
              stringsmith generate      산출물을 만듭니다
              stringsmith preview       번역 확인 앱을 띄웁니다

            'ss' 는 'stringsmith' 의 짧은 별칭입니다 — 'ss generate' 는 같은 명령입니다.
            'make install' 이 함께 만들어 주며, 내려받은 바이너리라면 직접 만듭니다:
              ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss

            입력은 CSV/TSV 파일 또는 Google Sheets URL 입니다. XLSX 는 이후 버전입니다.
            """),
        version: "0.1.0",
        subcommands: [Init.self, Generate.self, Preview.self]
    )
}

// MARK: - init

extension Stringsmith {
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: tr(
                "Draft a config from the sheet header.",
                "시트 헤더를 읽어 설정 초안을 만듭니다.")
        )

        @Argument(help: .init(stringLiteral: tr(
            "Path to a CSV or TSV file. Omit to search the current directory.",
            "CSV 또는 TSV 파일 경로. 생략하면 현재 디렉터리에서 찾습니다.")))
        var sheet: String?

        @Option(
            name: .long,
            help: .init(stringLiteral: tr(
                "Google Sheets share URL. Reads the sheet instead of a local file.",
                "Google Sheets 공유 URL. 로컬 파일 대신 이 시트를 읽습니다.")))
        var url: String?

        // `.short` 는 -h 가 되어 --help 와 충돌한다. -r 로 명시한다.
        @Option(name: [.customShort("r"), .long], help: .init(stringLiteral: tr(
            "Header row number, 1-based. Detected automatically if omitted.",
            "헤더가 있는 행 번호 (1부터). 생략하면 자동 감지합니다.")))
        var headerRow: Int?

        @Option(name: [.short, .long], help: .init(stringLiteral: tr(
            "Source locale. Inferred if omitted.",
            "원문 로케일. 생략하면 추론합니다.")))
        var sourceLocale: String?

        @Option(name: [.short, .long], help: .init(stringLiteral: tr("Output directory.", "산출물을 쓸 디렉터리.")))
        var output: String = "Resources"

        @Option(
            name: [.short, .long],
            help: .init(stringLiteral: tr("Config path.", "설정 파일 경로.")))
        var config: String = Configuration.defaultFileName

        @Option(
            name: .long, parsing: .upToNextOption,
            help: .init(stringLiteral: tr(
                "Artifacts to build. Both by default: xcstrings · swift",
                "만들 산출물. 기본은 둘 다: xcstrings · swift"))
        )
        var artifacts: [String] = ["xcstrings", "swift"]

        @Flag(name: [.short, .long], help: .init(stringLiteral: tr(
            "Overwrite an existing config.", "기존 설정 파일을 덮어씁니다.")))
        var force: Bool = false

        func run() throws {
            Stringsmith.configureBuffering()
            if FileManager.default.fileExists(atPath: config), !force {
                throw CLIError(tr(
                    """
                    A config already exists: \(config)
                      → Pass --force to overwrite it.
                    """,
                    """
                    설정 파일이 이미 있습니다: \(config)
                      → 덮어쓰려면 --force를 붙이세요.
                    """))
            }

            // URL 을 주면 그 자리에서 받아 헤더를 읽는다. 파일을 먼저 내려받지 않아도 된다.
            let sourceConfig: SourceConfig
            let rows: [[String]]
            if let url {
                print("ℹ️ " + tr("Fetching the sheet…", "시트를 가져오는 중…"))
                rows = try GoogleSheetsSource(url: url).rows()
                sourceConfig = SourceConfig(
                    type: "google-sheets", url: url, headerRow: 1, defaultLocale: "")
                guard !rows.isEmpty else { throw StringsmithError.emptySheet(path: url) }
            } else {
                let sheet = try resolveSheet()
                rows = try CSVParser.forFile(at: sheet).parseFile(at: sheet)
                guard !rows.isEmpty else { throw StringsmithError.emptySheet(path: sheet) }
                sourceConfig = SourceConfig(path: sheet, headerRow: 1, defaultLocale: "")
            }

            let headerRow = try resolveHeaderRow(in: rows)
            guard headerRow >= 1, headerRow <= rows.count else {
                throw StringsmithError.headerRowOutOfRange(requested: headerRow, totalRows: rows.count)
            }

            let headers = rows[headerRow - 1].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let result = MappingInference.infer(headers: headers)

            let columnCount = headers.filter { !$0.isEmpty }.count
            print(tr(
                "Found \(columnCount) columns in the sheet:",
                "시트에서 컬럼 \(columnCount)개를 찾았습니다:"))
            print("  \(headers.filter { !$0.isEmpty }.joined(separator: ", "))\n")

            guard let mapping = result.mapping else {
                throw CLIError(tr(
                    """
                    \(result.failureReason ?? "Could not infer a mapping.")
                      → Check --header-row, or write \(config) by hand.
                    """,
                    """
                    \(result.failureReason ?? "매핑을 추론하지 못했습니다.")
                      → --header-row 값이 맞는지 확인하거나, \(config)를 직접 작성하세요.
                    """))
            }

            let locale = try resolveSourceLocale(from: mapping)
            // 설정 안의 경로는 **설정 파일 위치 기준**으로 저장한다.
            // 그래야 저장소 어디서 실행하든, 다른 사람이 클론해도 같게 동작한다.
            let configDirectory = (config as NSString).deletingLastPathComponent
            var source = sourceConfig
            source.headerRow = headerRow
            source.defaultLocale = locale
            if source.type == "csv" {
                source.path = PathUtil.relative(from: configDirectory, to: source.path)
            }
            let configuration = Configuration(
                source: source,
                columns: mapping,
                output: OutputConfig(
                    artifacts: artifacts,
                    path: PathUtil.relative(from: configDirectory, to: output)
                )
            )

            do {
                try configuration.serialized().write(to: URL(fileURLWithPath: config))
            } catch {
                throw StringsmithError.io(path: config, reason: error.localizedDescription)
            }

            print(tr(
                "Saved the inferred mapping to \(config):",
                "추론된 매핑을 \(config)에 저장했습니다:"))
            print("  key    ← \"\(mapping.key)\"")
            if let screen = mapping.screen {
                print("  screen ← \"\(screen)\"  " + tr("(namespace, comment)", "(네임스페이스·주석)"))
            }
            if let desc = mapping.description {
                print("  desc   ← \"\(desc)\"  " + tr("(comment)", "(주석)"))
            }
            for code in mapping.languages.keys.sorted() {
                let marker = code == locale ? tr("  ← source", "  ← 원문") : ""
                print("  \(code.padded(to: 6)) ← \"\(mapping.languages[code]!)\"\(marker)")
            }
            print(tr("  artifacts ← ", "  산출물 ← ")
                + configuration.output.artifacts.joined(separator: ", "))
            if !result.unmapped.isEmpty {
                print("\n  ⚠️ " + tr("Unmapped columns (ignored): ", "매핑되지 않은 컬럼 (무시됨): ")
                    + result.unmapped.joined(separator: ", "))
            }
            print("\n" + tr(
                "Review it, then run: stringsmith generate",
                "확인 후 수정하세요. 다음: stringsmith generate"))
        }

        /// 시트 경로를 정한다. 생략하면 현재 디렉터리에서 CSV/TSV 를 찾는다.
        ///
        /// 후보가 정확히 하나일 때만 자동으로 고른다. 여럿이면 골라달라고 한다 —
        /// 잘못된 파일로 조용히 진행하는 것보다 낫다.
        private func resolveSheet() throws -> String {
            if let sheet { return sheet }
            let directory = FileManager.default.currentDirectoryPath
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { ["csv", "tsv"].contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()

            switch names.count {
            case 1:
                print("ℹ️ " + tr("Sheet: ", "시트: ") + names[0] + "\n")
                return names[0]
            case 0:
                throw CLIError(tr(
                    """
                    No CSV/TSV file in the current directory.
                      → Pass the path:  stringsmith init <sheet.csv>
                    """,
                    """
                    현재 디렉터리에서 CSV/TSV 파일을 찾지 못했습니다.
                      → 경로를 직접 지정하세요:  stringsmith init <시트.csv>
                    """))
            default:
                throw CLIError(tr(
                    """
                    More than one CSV/TSV here: \(names.joined(separator: ", "))
                      → Pick one:  stringsmith init \(names[0])
                    """,
                    """
                    CSV/TSV 파일이 여러 개입니다: \(names.joined(separator: ", "))
                      → 하나를 지정하세요:  stringsmith init \(names[0])
                    """))
            }
        }

        /// 헤더 행을 정한다. 명시값이 있으면 그대로, 없으면 자동 감지한다.
        private func resolveHeaderRow(in rows: [[String]]) throws -> Int {
            if let headerRow { return headerRow }
            guard let detected = MappingInference.detectHeaderRow(in: rows) else {
                throw CLIError(tr(
                    """
                    Could not find the header row.
                      Looked at the first \(min(15, rows.count)) rows for a row holding both a key
                      column ('key') and a language column ('ko', 'English', …).
                      → Pass --header-row to set it.
                    """,
                    """
                    헤더 행을 찾지 못했습니다.
                      위 \(min(15, rows.count))개 행에서 'key'/'키' 같은 키 컬럼과
                      '한국어'/'ko' 같은 언어 컬럼이 함께 있는 행을 찾지 못했습니다.
                      → --header-row 로 직접 지정하세요.
                    """))
            }
            if detected != 1 {
                print("ℹ️ " + tr(
                    "Header found on row \(detected).", "헤더를 \(detected)행에서 찾았습니다.") + "\n")
            }
            return detected
        }

        private func resolveSourceLocale(from mapping: ColumnMapping) throws -> String {
            if let sourceLocale {
                guard mapping.languages[sourceLocale] != nil else {
                    throw CLIError(tr(
                        """
                        No column for source locale "\(sourceLocale)".
                          Languages found: \(mapping.languages.keys.sorted().joined(separator: ", "))
                        """,
                        """
                        원문 로케일 "\(sourceLocale)"에 해당하는 컬럼이 없습니다.
                          찾은 언어: \(mapping.languages.keys.sorted().joined(separator: ", "))
                        """))
                }
                return sourceLocale
            }
            // 한국 팀 시트를 우선 가정하되, 없으면 사전순 첫 번째.
            for candidate in ["ko", "en"] where mapping.languages[candidate] != nil {
                return candidate
            }
            return mapping.languages.keys.sorted()[0]
        }
    }
}

// MARK: - build

extension Stringsmith {
    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: tr("Read the sheet and write the artifacts.", "시트를 읽어 산출물을 만듭니다."),
            discussion: tr(
                """
                Defaults to output.artifacts in the config.
                --only narrows it for one run.

                  xcstrings   String Catalog
                  swift       typed accessors (L10n.Order.title)
                """,
                """
                기본은 설정의 output.artifacts 를 따릅니다.
                --only 로 이번 실행만 골라낼 수 있습니다.

                  xcstrings   String Catalog
                  swift       타입세이프 접근자 (L10n.Order.title)
                """),
            aliases: ["build", "g"]
        )

        @Option(name: [.short, .long], help: .init(stringLiteral: tr(
            "Config path. Searched upward from here if omitted.",
            "설정 파일 경로. 생략하면 상위 디렉터리까지 찾습니다.")))
        var config: String?

        @Flag(name: [.customShort("n"), .long], help: .init(stringLiteral: tr(
            "Show what would change without writing.",
            "파일을 쓰지 않고 무엇이 바뀔지만 보여줍니다.")))
        var dryRun: Bool = false

        @Flag(name: [.short, .long], help: .init(stringLiteral: tr(
            "Show every variable conversion.", "변수 변환 내역을 전부 보여줍니다.")))
        var verbose: Bool = false

        @Option(
            name: .long,
            parsing: .upToNextOption,
            help: .init(stringLiteral: tr(
                "Artifacts for this run: xcstrings · swift",
                "이번 실행에서 만들 산출물: xcstrings · swift"))
        )
        var only: [String] = []

        func run() throws {
            Stringsmith.configureBuffering()
            let config = try Stringsmith.resolveConfigPath(self.config)
            let configuration = try Configuration.load(from: config)
            let base = (config as NSString).deletingLastPathComponent
            let pipeline = Pipeline(
                configuration: configuration,
                baseDirectory: base.isEmpty ? FileManager.default.currentDirectoryPath : base,
                only: only.isEmpty ? nil : only
            )

            let result = try pipeline.build(dryRun: dryRun)
            let table = result.table

            print("📄 " + tr(
                "\(table.entries.count) keys · \(table.locales.count) languages",
                "키 \(table.entries.count)개 · 언어 \(table.locales.count)개")
                + " (\(table.locales.joined(separator: ", ")))")

            for warning in result.warnings {
                print("  ⚠️ \(warning)")
            }

            // 문자열을 고쳤으면 반드시 보여준다. 말없이 바꾸는 도구는 신뢰를 잃는다.
            if !result.conversions.isEmpty {
                let shown = verbose ? result.conversions : Array(result.conversions.prefix(5))
                print("\n🔤 " + tr(
                    "\(result.conversions.count) variable conversions:",
                    "변수 변환 \(result.conversions.count)건:"))
                for conversion in shown {
                    print("  " + Terminal.dim("\(conversion.key) [\(conversion.locale)]"))
                    print("    " + Terminal.removed("- \(conversion.before)"))
                    print("    " + Terminal.added("+ \(conversion.after)"))
                }
                if shown.count < result.conversions.count {
                    let rest = result.conversions.count - shown.count
                    print("  … " + tr(
                        "\(rest) more (-v shows all)", "\(rest)건 더 (-v 로 전체 보기)"))
                }
                print("")
            }

            if dryRun {
                for path in result.written {
                    print("  ~ \(path) " + tr("(would change)", "(변경 예정)"))
                }
                for path in result.unchanged {
                    print("  = \(path) " + tr("(unchanged)", "(변경 없음)"))
                }
                print("\n" + tr("Dry run — nothing was written.", "dry-run 이므로 파일을 쓰지 않았습니다."))
            } else {
                for path in result.written { print("  ✅ \(path)") }
                for path in result.unchanged {
                    print("  = \(path) " + tr("(unchanged)", "(변경 없음)"))
                }
            }
        }

    }
}

// MARK: - preview

extension Stringsmith {
    struct Preview: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "preview",
            abstract: tr(
                "Open this project in the review app.", "번역 확인 앱에서 이 프로젝트를 엽니다."),
            discussion: tr(
                """
                The app reads the sheet directly, so generate does not have to run first.
                Use the refresh button (⌘R) after editing the sheet.

                Several projects can stay open as tabs.
                """,
                """
                앱은 시트를 그 자리에서 읽으므로 generate 를 먼저 돌릴 필요가 없습니다.
                앱 안의 갱신 버튼(⌘R)으로 시트 변경을 다시 읽습니다.

                프로젝트를 여러 개 열어두고 탭으로 오갈 수 있습니다.
                """)
        )

        @Option(
            name: [.short, .long],
            help: .init(stringLiteral: tr(
                "Config path. Searched upward from here if omitted.",
                "설정 파일 경로. 생략하면 상위 디렉터리까지 찾습니다.")))
        var config: String?

        func run() throws {
            let configPath = try Stringsmith.resolveConfigPath(config)
            // 설정이 읽히는지 먼저 확인한다. 앱을 띄운 뒤 오류를 보는 것보다 낫다.
            _ = try Configuration.load(from: configPath)

            let absolute =
                configPath.hasPrefix("/")
                ? configPath
                : (FileManager.default.currentDirectoryPath as NSString)
                    .appendingPathComponent(configPath)

            guard let app = Self.locateApp() else {
                throw CLIError(tr(
                    """
                    Could not find the review app.
                      → Install it with `make install-app`, or download it from Releases.
                    """,
                    """
                    번역 확인 앱을 찾을 수 없습니다.
                      → `make install-app` 으로 설치하거나 Releases 에서 내려받으세요.
                    """))
            }

            // 이미 떠 있는 앱에 먼저 알린다. 실행 중이 아니면 아무도 받지 않고 넘어간다.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("stringsmith.openProject"),
                object: absolute,
                userInfo: nil,
                deliverImmediately: true
            )

            // `open` 은 바로 돌아온다. 자식 프로세스를 직접 붙들면 셸이 멈춘다.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", app, "--args", absolute]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw CLIError(tr(
                    "Could not launch the app: \(error.localizedDescription)",
                    "앱을 실행할 수 없습니다: \(error.localizedDescription)"))
            }
            let name = (absolute as NSString).lastPathComponent
            print("▶︎ " + tr(
                "Opening \(name) in the review app", "\(name) 를 번역 확인 앱에서 엽니다"))
        }

        /// `.app` 번들 경로를 찾는다. 실행 파일 옆 → 홈 → /Applications 순.
        static func locateApp() -> String? {
            let name = "StringsmithPreview.app"
            let manager = FileManager.default
            let selfPath = (CommandLine.arguments[0] as NSString).resolvingSymlinksInPath
            let binDirectory = (selfPath as NSString).deletingLastPathComponent

            let candidates = [
                (NSHomeDirectory() as NSString).appendingPathComponent("Applications/\(name)"),
                "/Applications/\(name)",
                "\(binDirectory)/../Applications/\(name)",
                "\(binDirectory)/../../.build/\(name)",
            ]
            for path in candidates {
                let standardized = (path as NSString).standardizingPath
                if manager.fileExists(atPath: standardized) { return standardized }
            }
            return nil
        }
    }
}

// MARK: - 공용

extension Stringsmith {
    /// 설정 파일 위치를 정한다. 명시하지 않으면 상위 디렉터리까지 찾는다(git 과 같은 방식).
    static func resolveConfigPath(_ explicit: String?) throws -> String {
        if let explicit { return explicit }
        guard let discovered = Configuration.discover() else {
            throw CLIError(tr(
                """
                No \(Configuration.defaultFileName) found.
                  Searched from the current directory upward.
                  → Create one with `stringsmith init`, or pass --config.
                """,
                """
                \(Configuration.defaultFileName)을(를) 찾을 수 없습니다.
                  현재 디렉터리부터 상위까지 찾아봤습니다.
                  → stringsmith init 으로 만들거나, --config 로 경로를 지정하세요.
                """))
        }
        let local = (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(Configuration.defaultFileName)
        if discovered != local { print("ℹ️ " + tr("Config: ", "설정: ") + discovered) }
        return discovered
    }
}

// MARK: - 경로 유틸

enum PathUtil {
    /// `base` 디렉터리에서 `target`으로 가는 상대 경로를 만든다.
    ///
    /// 둘 다 현재 작업 디렉터리 기준으로 해석한다. 절대 경로 `target`은 그대로 둔다.
    static func relative(from base: String, to target: String) -> String {
        if target.hasPrefix("/") { return target }
        let cwd = FileManager.default.currentDirectoryPath
        let baseParts = normalize((cwd as NSString).appendingPathComponent(base))
        let targetParts = normalize((cwd as NSString).appendingPathComponent(target))

        var common = 0
        while common < baseParts.count, common < targetParts.count,
            baseParts[common] == targetParts[common]
        {
            common += 1
        }
        let up = Array(repeating: "..", count: baseParts.count - common)
        let down = targetParts[common...]
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// `.`·`..`·빈 조각을 정리한 경로 조각 배열.
    private static func normalize(_ path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(part)
            }
        }
        return result
    }
}

// MARK: - 오류 표현

/// CLI 단계에서만 발생하는 오류. `StringsmithError`와 동일하게 사람이 읽는 문장을 담는다.
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension CLIError: LocalizedError {
    var errorDescription: String? { description }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
