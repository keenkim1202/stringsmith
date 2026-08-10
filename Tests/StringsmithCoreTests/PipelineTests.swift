import Foundation
import Testing

@testable import StringsmithCore

@Suite("XCStrings 문서")
struct XCStringsTests {

    @Test("빈 번역은 넣지 않는다 — 누락이 감춰지면 안 된다")
    func emptyValuesOmitted() {
        let table = LocalizationTable(
            sourceLocale: "ko",
            entries: [
                LocalizationEntry(key: "a", values: ["ko": "가", "en": "", "ja": "ア"])
            ]
        )
        let document = XCStringsDocument(table: table)
        let localizations = document.strings["a"]?.localizations
        #expect(localizations?.keys.sorted() == ["ja", "ko"])
    }

    @Test("화면과 설명을 하나의 주석으로 합친다")
    func commentMerging() {
        let both = LocalizationEntry(key: "a", screen: "장바구니", comment: "개수 표시", values: [:])
        let screenOnly = LocalizationEntry(key: "b", screen: "설정", values: [:])
        let neither = LocalizationEntry(key: "c", values: [:])
        #expect(XCStringsDocument.comment(for: both) == "장바구니 — 개수 표시")
        #expect(XCStringsDocument.comment(for: screenOnly) == "설정")
        #expect(XCStringsDocument.comment(for: neither) == nil)
    }

    @Test("시트에서 온 키는 extractionState가 manual이다")
    func extractionStateIsManual() {
        let table = LocalizationTable(
            sourceLocale: "ko",
            entries: [LocalizationEntry(key: "a", values: ["ko": "가"])]
        )
        #expect(XCStringsDocument(table: table).strings["a"]?.extractionState == "manual")
    }

    @Test("직렬화는 결정적이다 — 같은 입력이면 바이트가 같다")
    func deterministicOutput() throws {
        func makeDocument() -> XCStringsDocument {
            XCStringsDocument(
                table: LocalizationTable(
                    sourceLocale: "ko",
                    entries: [
                        LocalizationEntry(key: "z", values: ["en": "Z", "ko": "지"]),
                        LocalizationEntry(key: "a", values: ["ko": "가", "en": "A"]),
                    ]
                )
            )
        }
        let first = try XCStringsWriter.data(for: makeDocument())
        let second = try XCStringsWriter.data(for: makeDocument())
        #expect(first == second)

        let text = String(decoding: first, as: UTF8.self)
        // 키가 정렬되어 나온다
        let aIndex = try #require(text.range(of: "\"a\""))
        let zIndex = try #require(text.range(of: "\"z\""))
        #expect(aIndex.lowerBound < zIndex.lowerBound)
        // 파일 끝 개행
        #expect(text.hasSuffix("\n"))
    }

    @Test("한글은 유니코드 이스케이프되지 않는다")
    func koreanNotEscaped() throws {
        let document = XCStringsDocument(
            table: LocalizationTable(
                sourceLocale: "ko",
                entries: [LocalizationEntry(key: "a", values: ["ko": "설정"])]
            )
        )
        let text = String(decoding: try XCStringsWriter.data(for: document), as: UTF8.self)
        #expect(text.contains("설정"))
        #expect(!text.contains("\\u"))
    }
}

@Suite("파이프라인")
struct PipelineTests {

    /// 임시 디렉터리에 시트를 쓰고 파이프라인을 만든다.
    private func makePipeline(
        csv: String,
        sourceLocale: String = "ko",
        headerRow: Int = 1,
        mapping: ColumnMapping = ColumnMapping(
            key: "키", screen: "화면", description: "설명",
            languages: ["ko": "한국어", "en": "영어"]
        )
    ) throws -> (Pipeline, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sheet = directory.appendingPathComponent("sheet.csv")
        try Data(csv.utf8).write(to: sheet)

        let configuration = Configuration(
            source: SourceConfig(path: "sheet.csv", headerRow: headerRow, defaultLocale: sourceLocale),
            columns: mapping,
            output: OutputConfig(path: "out")
        )
        return (
            Pipeline(configuration: configuration, baseDirectory: directory.path),
            directory.path
        )
    }

    @Test("시트를 읽어 테이블을 만든다")
    func loadsTable() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                settings.title,설정,화면 제목,설정,Settings
                cart.empty,장바구니,,장바구니가 비었습니다,Your cart is empty
                """
        )
        let table = try pipeline.loadTable()
        #expect(table.entries.count == 2)
        #expect(table.sourceLocale == "ko")
        #expect(table.locales == ["en", "ko"])
        #expect(table.entries[0].screen == "설정")
        #expect(table.entries[1].comment == nil)
    }

    /// 시트에서 앞뒤 공백을 지우면 다시 넣을 방법이 없다. `"{name} "` 처럼 뒤에 공백을 두고
    /// 다른 요소와 이어 붙이는 문구가 실제로 있다.
    @Test("번역 값의 앞뒤 공백은 의도로 보고 지우지 않는다")
    func keepsWhitespaceInTranslations() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                joined.prefix,본문,이어 붙이는 문구,"{name} ","{name} "
                indented.body,본문,들여쓴 줄,"  들여쓴 값","  indented  "
                """
        )
        let table = try pipeline.loadTable()

        #expect(table.entries[0].values["ko"] == "{name} ")
        #expect(table.entries[0].values["en"] == "{name} ")
        #expect(table.entries[1].values["ko"] == "  들여쓴 값")
        #expect(table.entries[1].values["en"] == "  indented  ")
    }

    /// 값은 그대로 두더라도, 있는지 없는지는 다듬어서 판단해야 한다. 공백만 있는 칸을 번역으로
    /// 받으면 미번역 경고가 뜨지 않아 빠진 번역을 놓친다.
    @Test("공백만 있는 칸은 번역이 아니라 빈 칸이다")
    func treatsWhitespaceOnlyAsMissing() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                blank.translation,본문,공백만 있는 번역,있음,"   "
                """
        )
        let table = try pipeline.loadTable()
        #expect(table.entries[0].values["ko"] == "있음")
        #expect(table.entries[0].values["en"] == nil)
    }

    /// 키에 앞뒤 공백이 붙으면 Swift 식별자가 깨지고, 같은 키가 둘로 갈린다.
    @Test("키·화면·설명은 계속 다듬는다")
    func stillTrimsIdentifiers() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                "  settings.title  ","  설정  ","  화면 제목  ",설정,Settings
                """
        )
        let table = try pipeline.loadTable()
        #expect(table.entries[0].key == "settings.title")
        #expect(table.entries[0].screen == "설정")
        #expect(table.entries[0].comment == "화면 제목")
    }

    @Test("빈 행을 건너뛰고 원본 행 번호를 유지한다")
    func skipsBlankRowsKeepingRowNumbers() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                a,,,가,A
                ,,,,
                b,,,나,B
                """
        )
        let table = try pipeline.loadTable()
        #expect(table.entries.map(\.key) == ["a", "b"])
        #expect(table.entries[0].sourceRow == 2)
        #expect(table.entries[1].sourceRow == 4)  // 빈 행을 세고도 실제 행 번호
    }

    @Test("헤더 행 위치를 지정할 수 있다")
    func headerRowOffset() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                이 시트는 번역 관리용입니다
                키,화면,설명,한국어,영어
                a,,,가,A
                """,
            headerRow: 2
        )
        #expect(try pipeline.loadTable().entries.count == 1)
    }

    @Test("키가 중복되면 행 번호와 함께 실패한다")
    func duplicateKeyFails() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                a,,,가,A
                a,,,다시,Again
                """
        )
        do {
            _ = try pipeline.loadTable()
            Issue.record("던져야 한다")
        } catch let error as StringsmithError {
            guard case let .duplicateKey(key, rows) = error else {
                Issue.record("duplicateKey 여야 한다: \(error)")
                return
            }
            #expect(key == "a")
            #expect(rows == [2, 3])
        }
    }

    @Test("원문 값이 비면 실패한다")
    func emptySourceValueFails() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                a,,,,A
                """
        )
        #expect(throws: StringsmithError.self) { try pipeline.loadTable() }
    }

    @Test("없는 컬럼은 실제 컬럼 목록을 담아 실패한다")
    func missingColumnFails() throws {
        let (pipeline, _) = try makePipeline(
            csv: """
                키,한국어
                a,가
                """,
            mapping: ColumnMapping(key: "키", languages: ["ko": "한국어", "en": "영어"])
        )
        do {
            _ = try pipeline.loadTable()
            Issue.record("던져야 한다")
        } catch let error as StringsmithError {
            guard case let .columnNotFound(requested, role, available, _) = error else {
                Issue.record("columnNotFound 여야 한다: \(error)")
                return
            }
            #expect(requested == "영어")
            #expect(role == "languages.en")
            #expect(available == ["키", "한국어"])
        }
    }

    @Test("기본 산출물은 .xcstrings 와 L10n.swift 두 개다")
    func defaultArtifacts() throws {
        let (pipeline, directory) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                settings.title,설정,,설정,Settings
                """
        )
        let result = try pipeline.build()
        #expect(result.written.count == 2)
        #expect(result.written.contains { $0.hasSuffix("Localizable.xcstrings") })
        #expect(result.written.contains { $0.hasSuffix("L10n.swift") })
        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("--only 로 산출물을 골라낼 수 있다")
    func onlySelectsArtifacts() throws {
        let (base, directory) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                settings.title,설정,,설정,Settings
                """
        )
        let pipeline = Pipeline(
            configuration: base.configuration,
            baseDirectory: base.baseDirectory,
            only: ["xcstrings"]
        )
        let result = try pipeline.build()
        #expect(result.written.count == 1)
        #expect(result.written[0].hasSuffix("Localizable.xcstrings"))
        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("build가 산출물을 쓰고, 두 번째 실행은 변경 없음으로 보고한다")
    func buildIsIdempotent() throws {
        let (pipeline, directory) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                settings.title,설정,,설정,Settings
                """
        )
        let first = try pipeline.build()
        #expect(first.written.count == 2)
        #expect(first.unchanged.isEmpty)
        for path in first.written {
            #expect(FileManager.default.fileExists(atPath: path))
        }

        let second = try pipeline.build()
        #expect(second.written.isEmpty)
        #expect(second.unchanged.count == 2)

        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("dry-run은 파일을 쓰지 않는다")
    func dryRunWritesNothing() throws {
        let (pipeline, directory) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                a,,,가,A
                """
        )
        let result = try pipeline.build(dryRun: true)
        #expect(result.written.count == 2)
        for path in result.written {
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("번역 누락은 경고로만 보고한다 — 빌드를 막지 않는다")
    func missingTranslationsWarnOnly() throws {
        let (pipeline, directory) = try makePipeline(
            csv: """
                키,화면,설명,한국어,영어
                a,,,가,A
                b,,,나,
                """
        )
        let result = try pipeline.build(dryRun: true)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("en"))
        #expect(result.table.entries.count == 2)
        try? FileManager.default.removeItem(atPath: directory)
    }
}
