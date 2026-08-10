import Foundation
import Testing

@testable import StringsmithCore

/// 저장소에 든 실제 `.xlsx` 로 확인한다.
///
/// 손으로 만든 XML 문자열만 보면 ZIP 판독이 검증되지 않는다 — 압축 해제도, 중앙 디렉터리
/// 파싱도 진짜 파일이라야 걸린다.
@Suite("XLSX 읽기")
struct XLSXTests {

    /// `Examples/sample-sheet.xlsx`. 테스트는 패키지 루트에서 돌아간다.
    var fixture: String {
        // #filePath 에서 거슬러 올라간다. 작업 디렉터리에 기대지 않는다.
        let file = URL(fileURLWithPath: #filePath)
        return
            file
            .deletingLastPathComponent()  // StringsmithCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 루트
            .appendingPathComponent("Examples/sample-sheet.xlsx")
            .path
    }

    // MARK: ZIP

    @Test("압축된 항목과 저장된 항목을 모두 읽는다")
    func readsBothStorageMethods() throws {
        let archive = try ZipArchive(path: fixture)

        #expect(archive.names.contains("xl/workbook.xml"))
        #expect(archive.names.contains("xl/sharedStrings.xml"))
        // 압축하지 않고 넣은 항목.
        let stored = try #require(archive.contents(of: "docProps/app.xml"))
        #expect(String(decoding: stored, as: UTF8.self).contains("<Properties/>"))
    }

    @Test("ZIP 이 아니면 그렇다고 말한다")
    func rejectsNonArchives() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("이건 zip 이 아닙니다".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: StringsmithError.self) { try ZipArchive(path: path) }
    }

    // MARK: 통합 문서

    @Test("시트 이름을 순서대로 읽는다")
    func readsSheetNames() throws {
        #expect(try XLSXReader(path: fixture).sheetNames() == ["번역", "메모"])
    }

    @Test("첫 시트를 행 × 열로 읽는다")
    func readsTheFirstSheet() throws {
        let rows = try XLSXReader(path: fixture).rows()

        #expect(rows.count == 4)
        #expect(rows[0] == ["key", "screen", "ko", "en"])
        #expect(rows[1] == ["home.title", "홈", "홈 & <중요>", "Home"])
    }

    /// 빈 칸은 파일에 아예 없다. `r="D3"` 을 안 보고 순서대로 넣으면 ko 가 en 으로 읽힌다.
    @Test("빠진 칸이 있어도 열이 밀리지 않는다")
    func keepsColumnsAligned() throws {
        let rows = try XLSXReader(path: fixture).rows()
        // 3행은 en 이 비어 있다.
        #expect(rows[2] == ["cart.empty", "장바구니", "장바구니가 비었습니다"])
    }

    /// 서식이 섞인 칸은 `<t>` 여러 개로 쪼개져 있다. 이어 붙이지 않으면 잘린다.
    @Test("조각난 문자열을 이어 붙인다")
    func joinsSplitRuns() throws {
        let rows = try XLSXReader(path: fixture).rows()
        #expect(rows[3][0] == "multi.line")
    }

    @Test("XML 이스케이프를 되돌린다")
    func unescapesEntities() throws {
        let rows = try XLSXReader(path: fixture).rows()
        #expect(rows[1][2] == "홈 & <중요>")
        // 숫자 참조로 들어간 개행.
        #expect(rows[3][2] == "첫 줄\n둘째 줄")
    }

    @Test("뒤쪽 빈 행은 떨어낸다")
    func dropsTrailingBlankRows() throws {
        // 파일에는 <row r="5"/> 가 있다. 엑셀은 손댄 적 있는 행을 빈 채로 남긴다.
        #expect(try XLSXReader(path: fixture).rows().count == 4)
    }

    @Test("이름으로 시트를 고른다")
    func selectsBySheetName() throws {
        #expect(try XLSXReader(path: fixture).rows(named: "메모").isEmpty)
    }

    @Test("없는 시트는 있는 것을 알려 준다")
    func listsSheetsWhenNameIsWrong() {
        do {
            _ = try XLSXReader(path: fixture).rows(named: "없는시트")
            Issue.record("없는 시트인데 통과했습니다")
        } catch let error as StringsmithError {
            #expect(error.description.contains("번역"))
            #expect(error.description.contains("메모"))
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("소스로 꽂으면 그대로 흘러간다")
    func worksAsASheetSource() throws {
        let source = XLSXSource(path: fixture)
        #expect(try source.contents().rows[0] == ["key", "screen", "ko", "en"])
    }

    // MARK: 열 이름

    @Test("열 이름을 번호로 바꾼다")
    func mapsColumnLetters() {
        #expect(XLSXReader.columnIndex(of: "A1") == 0)
        #expect(XLSXReader.columnIndex(of: "B2") == 1)
        #expect(XLSXReader.columnIndex(of: "Z9") == 25)
        // 26 을 넘으면 두 글자가 된다.
        #expect(XLSXReader.columnIndex(of: "AA1") == 26)
        #expect(XLSXReader.columnIndex(of: "AB1") == 27)
        #expect(XLSXReader.columnIndex(of: "BA10") == 52)
    }
}

// MARK: - XML 훑기

@Suite("XML 훑기")
struct XMLScanTests {

    @Test("속성을 읽는다")
    func readsAttributes() {
        let xml = #"<sheets><sheet name="번역" sheetId="1"/><sheet name="메모" sheetId="2"/></sheets>"#
        let found = XMLScan.attributes(in: Data(xml.utf8), element: "sheet")
        #expect(found.map { $0["name"] } == ["번역", "메모"])
    }

    /// `<c>` 를 찾을 때 `<col>` 에 걸리면 셀이 아닌 것을 셀로 읽는다.
    @Test("이름이 겹치는 요소에 걸리지 않는다")
    func doesNotMatchLongerNames() {
        let xml = #"<cols><col min="1" max="1"/></cols><c r="A1"><v>7</v></c>"#
        let found = XMLScan.elements(in: xml, element: "c")
        #expect(found.count == 1)
        #expect(found[0].attributes["r"] == "A1")
    }

    /// `&amp;` 를 먼저 풀면 `&amp;lt;` 가 `<` 가 되어 글자였던 것이 태그가 된다.
    @Test("실체 참조를 올바른 순서로 되돌린다")
    func unescapesInTheRightOrder() {
        #expect(XMLScan.unescape("a &amp;lt; b") == "a &lt; b")
        #expect(XMLScan.unescape("&lt;b&gt; &amp; &quot;q&quot;") == "<b> & \"q\"")
        #expect(XMLScan.unescape("줄&#10;바꿈") == "줄\n바꿈")
        #expect(XMLScan.unescape("&#x41;") == "A")
    }

    @Test("이스케이프가 없으면 그대로 둔다")
    func leavesPlainTextAlone() {
        #expect(XMLScan.unescape("평범한 값") == "평범한 값")
    }
}
