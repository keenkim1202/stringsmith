import Foundation
import Testing

@testable import StringsmithCore

@Suite("Sheets API")
struct SheetsAPITests {

    func json(_ status: Int, _ body: String) -> SheetResponse {
        SheetResponse(status: status, mimeType: "application/json", body: Data(body.utf8))
    }

    let metadata = #"""
        {"sheets":[
          {"properties":{"sheetId":0,"title":"Sheet1"}},
          {"properties":{"sheetId":874512,"title":"번역 v2"}}
        ]}
        """#

    /// URL 별로 다른 응답을 주는 가짜 서버.
    func server(values: String, seen: Captured? = nil) -> HTTPFetch {
        let metadata = metadata
        return { request in
            let url = request.url?.absoluteString ?? ""
            seen?.body = url
            if url.contains("/values/") {
                return SheetResponse(
                    status: 200, mimeType: "application/json", body: Data(values.utf8))
            }
            return SheetResponse(
                status: 200, mimeType: "application/json", body: Data(metadata.utf8))
        }
    }

    @Test("토큰을 Bearer 헤더로 보낸다")
    func sendsTheBearerToken() throws {
        let headers = Captured()
        let api = GoogleSheetsAPI(accessToken: "TOKEN") { request in
            headers.body = request.value(forHTTPHeaderField: "Authorization")
            return self.json(200, #"{"values":[["a"]]}"#)
        }
        _ = try api.values(spreadsheetID: "ID", range: "Sheet1")
        #expect(headers.body == "Bearer TOKEN")
    }

    @Test("gid 를 탭 이름으로 바꾼다")
    func resolvesGidToATabName() throws {
        let api = GoogleSheetsAPI(accessToken: "T", fetch: server(values: "{}"))

        #expect(try api.sheetTitle(spreadsheetID: "ID", gid: "874512") == "번역 v2")
        #expect(try api.sheetTitle(spreadsheetID: "ID", gid: "0") == "Sheet1")
        // gid 가 없으면 첫 번째 탭을 쓴다.
        #expect(try api.sheetTitle(spreadsheetID: "ID", gid: nil) == "Sheet1")
    }

    /// gid 는 URL 에서 그대로 복사되므로 오타가 흔하다. 있는 탭을 보여 줘야 고칠 수 있다.
    @Test("없는 gid 는 있는 탭 목록과 함께 알려 준다")
    func listsTabsWhenTheGidIsWrong() {
        let api = GoogleSheetsAPI(accessToken: "T", fetch: server(values: "{}"))
        do {
            _ = try api.sheetTitle(spreadsheetID: "ID", gid: "999")
            Issue.record("없는 gid 인데 통과했습니다")
        } catch let error as StringsmithError {
            #expect(error.description.contains("번역 v2"))
            #expect(error.description.contains("874512"))
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("탭 이름에 공백·한글이 있어도 주소가 깨지지 않는다")
    func encodesTheTabNameIntoTheURL() throws {
        let seen = Captured()
        let api = GoogleSheetsAPI(
            accessToken: "T", fetch: server(values: #"{"values":[["a"]]}"#, seen: seen))

        _ = try api.rows(spreadsheetID: "ID", gid: "874512")
        // 인코딩하지 않으면 URL 이 만들어지지 않거나 엉뚱한 범위를 읽는다.
        #expect(seen.body?.contains(" ") == false)
        #expect(seen.body?.contains("/values/") == true)
    }

    @Test("행 × 열을 그대로 돌려준다")
    func returnsRowsAsGiven() throws {
        let api = GoogleSheetsAPI(
            accessToken: "T",
            fetch: server(values: #"{"values":[["key","ko","en"],["greeting","안녕","hi"]]}"#))

        let rows = try api.rows(spreadsheetID: "ID", gid: nil)
        #expect(rows == [["key", "ko", "en"], ["greeting", "안녕", "hi"]])
    }

    /// 구글은 뒤쪽 빈 칸을 응답에서 빼 버려 행마다 길이가 달라진다.
    @Test("길이가 다른 행도 그대로 통과시킨다")
    func toleratesRaggedRows() throws {
        let api = GoogleSheetsAPI(
            accessToken: "T", fetch: server(values: #"{"values":[["a","b","c"],["d"]]}"#))

        let rows = try api.rows(spreadsheetID: "ID", gid: nil)
        #expect(rows == [["a", "b", "c"], ["d"]])
    }

    @Test("완전히 빈 시트는 빈 배열이 된다")
    func handlesAnEmptySheet() throws {
        let api = GoogleSheetsAPI(accessToken: "T", fetch: server(values: "{}"))
        #expect(try api.rows(spreadsheetID: "ID", gid: nil).isEmpty)
    }

    @Test("상태 코드마다 무엇을 해야 하는지 알려 준다")
    func explainsEachFailure() {
        #expect(GoogleSheetsAPI.explain(json(401, "{}")).contains("ss auth login"))
        #expect(GoogleSheetsAPI.explain(json(403, "{}")).contains("ss auth login"))
        // 404 는 로그인 문제가 아니라 주소 문제다. 로그인하라고 하면 헤매게 된다.
        #expect(GoogleSheetsAPI.explain(json(404, "{}")).contains("ss auth login") == false)
        #expect(GoogleSheetsAPI.explain(json(429, "{}")).contains("429"))

        let detailed = GoogleSheetsAPI.explain(json(500, #"{"error":{"message":"boom"}}"#))
        #expect(detailed.contains("boom"))
    }
}

// MARK: - 소스 선택

@Suite("Google Sheets 소스 — 인증 경로 선택")
struct GoogleSheetsSourceAuthTests {

    let url = "https://docs.google.com/spreadsheets/d/SHEET_ID/edit#gid=0"

    @Test("로그인되어 있지 않으면 공개 CSV 내보내기를 쓴다")
    func fallsBackToThePublicExport() throws {
        let source = GoogleSheetsSource(
            url: url,
            tokens: InMemoryTokenStore(),  // 비어 있음 = 로그인 안 됨
            fetch: { _ in
                SheetResponse(status: 200, mimeType: "text/csv", body: Data("key,ko\na,안녕".utf8))
            },
            authorized: { _ in
                Issue.record("로그인하지 않았는데 API 를 불렀습니다")
                return SheetResponse(status: 500, mimeType: nil, body: Data())
            })

        #expect(try source.rows() == [["key", "ko"], ["a", "안녕"]])
    }

    @Test("로그인되어 있으면 Sheets API 를 쓴다")
    func prefersTheAPIWhenSignedIn() throws {
        let store = InMemoryTokenStore(
            tokens: OAuthTokens(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600)))

        let source = GoogleSheetsSource(
            url: url,
            tokens: store,
            fetch: { _ in
                Issue.record("로그인했는데 공개 링크로 읽었습니다")
                return SheetResponse(status: 500, mimeType: nil, body: Data())
            },
            authorized: { request in
                let body =
                    (request.url?.absoluteString.contains("/values/") ?? false)
                    ? #"{"values":[["key","ko"],["a","안녕"]]}"#
                    : #"{"sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}}]}"#
                return SheetResponse(
                    status: 200, mimeType: "application/json", body: Data(body.utf8))
            })

        #expect(try source.rows() == [["key", "ko"], ["a", "안녕"]])
    }

    /// 오프라인 대비 캐시는 인증 경로에서도 남아야 한다.
    @Test("API 로 읽은 내용도 캐시에 남는다")
    func cachesWhatTheAPIReturned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let cache = directory.appendingPathComponent("sheet.csv").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InMemoryTokenStore(
            tokens: OAuthTokens(
                accessToken: "AT", refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600)))

        let source = GoogleSheetsSource(
            url: url, cachePath: cache, tokens: store,
            fetch: { _ in SheetResponse(status: 500, mimeType: nil, body: Data()) },
            authorized: { request in
                let body =
                    (request.url?.absoluteString.contains("/values/") ?? false)
                    ? #"{"values":[["key","ko"],["a","쉼표, 포함"]]}"#
                    : #"{"sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}}]}"#
                return SheetResponse(
                    status: 200, mimeType: "application/json", body: Data(body.utf8))
            })

        _ = try source.rows()

        let cached = try String(contentsOfFile: cache, encoding: .utf8)
        // 쉼표가 든 값은 따옴표로 감싸야 다시 읽을 때 열이 밀리지 않는다.
        #expect(cached.contains("\"쉼표, 포함\""))
        #expect(CSVParser().parse(cached) == [["key", "ko"], ["a", "쉼표, 포함"]])
    }
}

// MARK: - CSV 직렬화

@Suite("CSV 직렬화")
struct CSVSerializeTests {

    @Test("특수문자가 있는 값만 따옴표로 감싼다")
    func quotesOnlyWhenNeeded() {
        #expect(CSVParser.serialize([["a", "b"]]) == "a,b")
        #expect(CSVParser.serialize([["a,b"]]) == "\"a,b\"")
        #expect(CSVParser.serialize([["a\nb"]]) == "\"a\nb\"")
        // 안쪽 따옴표는 겹쳐 쓴다 (RFC 4180).
        #expect(CSVParser.serialize([["say \"hi\""]]) == "\"say \"\"hi\"\"\"")
    }

    @Test("직렬화한 것을 다시 읽으면 원래대로 돌아온다")
    func roundTrips() {
        let rows = [
            ["key", "ko", "en"],
            ["greeting", "안녕, 반가워", "hi"],
            ["quote", "그가 \"좋다\"고 했다", "he said \"ok\""],
            ["multi", "첫 줄\n둘째 줄", "one\ntwo"],
            ["ragged", "값 하나만"],
        ]
        #expect(CSVParser().parse(CSVParser.serialize(rows)) == rows)
    }
}

// MARK: - 안내 문구 회귀

@Suite("공개 링크 실패 안내")
struct PublicExportGuidanceTests {

    /// 서비스 계정 경로는 2026-08-10 에 폐기됐다. 안내가 없는 방법을 가리키면 안 된다.
    @Test("비공개 시트는 로그인을 안내한다")
    func pointsAtSignIn() throws {
        let source = GoogleSheetsSource(
            url: "https://docs.google.com/spreadsheets/d/ID/edit",
            fetch: { _ in
                SheetResponse(status: 404, mimeType: "text/html", body: Data("<!doctype html>".utf8))
            })

        do {
            _ = try source.rows()
            Issue.record("비공개 시트인데 통과했습니다")
        } catch let error as StringsmithError {
            #expect(error.description.contains("ss auth login"))
            #expect(error.description.lowercased().contains("service account") == false)
        }
    }
}
