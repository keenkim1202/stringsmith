import Foundation
import Testing

@testable import StringsmithCore

@Suite("여러 탭 이어 붙이기")
struct MultiTabTests {

    let url = "https://docs.google.com/spreadsheets/d/SHEET_ID/edit"

    /// gid 별로 다른 CSV 를 돌려주는 가짜 공개 링크.
    func publicSheet(_ byGid: [String: String]) -> SheetFetch {
        { url in
            let gid =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "gid" }?.value ?? ""
            let body = byGid[gid] ?? ""
            return SheetResponse(status: 200, mimeType: "text/csv", body: Data(body.utf8))
        }
    }

    @Test("탭 두 개를 위에서 아래로 이어 붙인다")
    func joinsTwoTabs() throws {
        let source = GoogleSheetsSource(
            url: url, tabs: ["0", "77"],
            fetch: publicSheet([
                "0": "key,ko\nhome.title,홈\nhome.body,본문",
                "77": "key,ko\ncart.title,장바구니\ncart.body,내용",
            ]))

        // 헤더는 한 번만, 데이터는 탭 순서대로.
        #expect(try source.rows() == [
            ["key", "ko"],
            ["home.title", "홈"], ["home.body", "본문"],
            ["cart.title", "장바구니"], ["cart.body", "내용"],
        ])
    }

    @Test("탭 순서를 지정한 대로 따른다")
    func keepsTheGivenOrder() throws {
        let sheets = publicSheet([
            "0": "key,ko\na,가",
            "77": "key,ko\nb,나",
        ])
        let forward = GoogleSheetsSource(url: url, tabs: ["0", "77"], fetch: sheets)
        let backward = GoogleSheetsSource(url: url, tabs: ["77", "0"], fetch: sheets)

        #expect(try forward.rows() == [["key", "ko"], ["a", "가"], ["b", "나"]])
        #expect(try backward.rows() == [["key", "ko"], ["b", "나"], ["a", "가"]])
    }

    /// 열이 어긋난 채 이어 붙으면 값이 엉뚱한 컬럼으로 들어간다. 조용히 섞이면 안 된다.
    @Test("컬럼이 다르면 이어 붙이지 않고 멈춘다")
    func refusesMismatchedColumns() {
        let source = GoogleSheetsSource(
            url: url, tabs: ["0", "77"],
            fetch: publicSheet([
                "0": "key,ko,en\na,가,A",
                "77": "key,en,ko\nb,B,나",
            ]))

        do {
            _ = try source.rows()
            Issue.record("컬럼이 다른데 통과했습니다")
        } catch let error as StringsmithError {
            // 어느 탭이 어떻게 다른지 보여 줘야 고칠 수 있다.
            #expect(error.description.contains("\"0\""))
            #expect(error.description.contains("\"77\""))
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    /// 시트는 뒤쪽 빈 칸을 응답에서 빼 버려 탭마다 헤더 길이가 달라진다.
    @Test("뒤쪽 빈 칸과 앞뒤 공백은 차이로 보지 않는다")
    func ignoresTrailingBlanksAndPadding() throws {
        let source = GoogleSheetsSource(
            url: url, tabs: ["0", "77"],
            fetch: publicSheet([
                "0": "key,ko,,\na,가",
                "77": "key, ko \nb,나",
            ]))
        #expect(try source.rows() == [["key", "ko", "", ""], ["a", "가"], ["b", "나"]])
    }

    @Test("아직 안 채운 빈 탭은 건너뛴다")
    func skipsEmptyTabs() throws {
        let source = GoogleSheetsSource(
            url: url, tabs: ["0", "77", "88"],
            fetch: publicSheet([
                "0": "key,ko\na,가",
                "77": "",
                "88": "key,ko\nc,다",
            ]))
        #expect(try source.rows() == [["key", "ko"], ["a", "가"], ["c", "다"]])
    }

    /// 헤더 위에 제목·안내 행을 둔 시트가 흔하다. 그 행은 첫 탭 것만 남긴다.
    @Test("헤더 위 안내 행은 첫 탭 것만 남는다")
    func keepsThePreambleFromTheFirstTabOnly() throws {
        let source = GoogleSheetsSource(
            url: url, tabs: ["0", "77"], headerRow: 3,
            fetch: publicSheet([
                "0": "번역 시트,,\n담당 keen,,\nkey,ko\na,가",
                "77": "장바구니 탭,,\n담당 lee,,\nkey,ko\nb,나",
            ]))

        let rows = try source.rows()
        #expect(rows[0] == ["번역 시트", "", ""])
        #expect(rows[2] == ["key", "ko"])
        // 두 번째 탭의 안내 행과 헤더는 들어오지 않는다.
        #expect(rows.contains(["장바구니 탭", "", ""]) == false)
        #expect(rows.filter { $0 == ["key", "ko"] }.count == 1)
        #expect(rows.last == ["b", "나"])
    }

    @Test("탭이 하나면 기존 경로 그대로다")
    func singleTabIsUnchanged() throws {
        let source = GoogleSheetsSource(
            url: url, tabs: ["77"], fetch: publicSheet(["77": "key,ko\nb,나"]))
        #expect(try source.rows() == [["key", "ko"], ["b", "나"]])
    }

    /// 공개 링크로는 gid 만 쓸 수 있다. 이름을 gid 로 바꾸려면 API 가 필요하다.
    @Test("로그인하지 않고 탭 이름을 쓰면 무엇을 해야 하는지 알려 준다")
    func explainsThatNamesNeedSignIn() {
        let source = GoogleSheetsSource(
            url: url, tabs: ["strings", "errors"],
            fetch: publicSheet([:]))

        do {
            _ = try source.rows()
            Issue.record("이름을 썼는데 통과했습니다")
        } catch let error as StringsmithError {
            #expect(error.description.contains("ss auth login"))
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("로그인되어 있으면 탭 이름으로도 이어 붙인다")
    func joinsByNameWhenSignedIn() throws {
        let store = InMemoryTokenStore(
            tokens: OAuthTokens(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600)))

        let source = GoogleSheetsSource(
            url: url, tabs: ["strings", "errors"], tokens: store,
            fetch: { _ in
                Issue.record("로그인했는데 공개 링크로 읽었습니다")
                return SheetResponse(status: 500, mimeType: nil, body: Data())
            },
            authorized: { request in
                let address = request.url?.absoluteString ?? ""
                let body: String
                if address.contains("/values/") {
                    body = address.contains("errors")
                        ? #"{"values":[["key","ko"],["bad","나쁨"]]}"#
                        : #"{"values":[["key","ko"],["good","좋음"]]}"#
                } else {
                    body = #"""
                        {"sheets":[
                          {"properties":{"sheetId":0,"title":"strings"}},
                          {"properties":{"sheetId":77,"title":"errors"}}
                        ]}
                        """#
                }
                return SheetResponse(
                    status: 200, mimeType: "application/json", body: Data(body.utf8))
            })

        #expect(try source.rows() == [["key", "ko"], ["good", "좋음"], ["bad", "나쁨"]])
    }
}

// MARK: - 오류가 가리키는 자리

@Suite("이어 붙였을 때의 행 번호")
struct MergedRowOriginTests {

    /// 이어 붙인 표의 행 번호만 주면 사람이 찾아갈 수 없다. 병합본 5행이 두 번째 탭의
    /// 2행일 수 있기 때문이다.
    @Test("각 행이 원래 어느 탭 몇 행이었는지 들고 온다")
    func carriesTheOriginOfEachRow() throws {
        let contents = try StubTabs([
            ("strings", [["key", "ko"], ["a", "가"], ["b", "나"]]),
            ("errors", [["key", "ko"], ["c", "다"]]),
        ]).contents()

        #expect(contents.rows.count == 4)  // 헤더 1 + 데이터 3
        #expect(contents.origin(at: 0) == SheetOrigin(tab: "strings", row: 1))
        #expect(contents.origin(at: 2) == SheetOrigin(tab: "strings", row: 3))
        // 병합본 4행째가 errors 탭의 2행이다.
        #expect(contents.origin(at: 3) == SheetOrigin(tab: "errors", row: 2))
    }

    @Test("중복 키 오류가 어느 탭 몇 행인지 짚는다")
    func namesTheTabInDuplicateErrors() throws {
        let pipeline = try makePipeline(
            StubTabs([
                ("strings", [["키", "한국어"], ["a", "가"], ["dup", "첫 번째"]]),
                ("errors", [["키", "한국어"], ["dup", "두 번째"]]),
            ]))

        do {
            _ = try pipeline.loadTable()
            Issue.record("중복 키인데 통과했습니다")
        } catch let error as StringsmithError {
            guard case let .duplicateKey(key, rows) = error else {
                Issue.record("duplicateKey 여야 한다: \(error)")
                return
            }
            #expect(key == "dup")
            // "3, 4" 가 아니라 어느 탭 몇 행인지 나와야 한다.
            #expect(rows == ["strings!3", "errors!2"])
        }
    }

    @Test("탭이 하나면 표기가 지금까지와 같다")
    func keepsPlainNumbersForASingleTab() throws {
        let pipeline = try makePipeline(
            StubTabs([("시트1", [["키", "한국어"], ["a", "가"], ["a", "또 가"]])]))
        do {
            _ = try pipeline.loadTable()
            Issue.record("중복 키인데 통과했습니다")
        } catch let error as StringsmithError {
            guard case let .duplicateKey(_, rows) = error else { return }
            #expect(rows == ["2", "3"])
        }
    }

    // MARK: 도우미

    /// 탭별 행을 그대로 돌려주는 가짜 소스. 네트워크 없이 병합 결과만 본다.
    struct StubTabs: SheetSource {
        let tabs: [(String, [[String]])]
        init(_ tabs: [(String, [[String]])]) { self.tabs = tabs }

        func contents() throws -> SheetContents {
            var rows: [[String]] = []
            var origins: [SheetOrigin] = []
            for (index, (tab, tabRows)) in tabs.enumerated() {
                // 첫 탭은 헤더까지, 나머지는 헤더를 건너뛴다.
                let start = index == 0 ? 0 : 1
                for offset in start..<tabRows.count {
                    rows.append(tabRows[offset])
                    origins.append(SheetOrigin(tab: tab, row: offset + 1))
                }
            }
            // 탭이 하나면 출처를 싣지 않는다 — 지금까지의 표기를 그대로 둔다.
            return SheetContents(rows: rows, origins: tabs.count > 1 ? origins : [])
        }
    }

    func makePipeline(_ source: StubTabs) throws -> Pipeline {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = Configuration(
            source: SourceConfig(path: "sheet.csv", defaultLocale: "ko"),
            columns: ColumnMapping(key: "키", languages: ["ko": "한국어"]),
            output: OutputConfig(path: "out")
        )
        return Pipeline(
            configuration: configuration, baseDirectory: directory.path, source: source)
    }
}
