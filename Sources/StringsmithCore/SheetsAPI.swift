import Foundation

/// Sheets API v4 로 시트 값을 읽는다.
///
/// 공개 CSV 내보내기와 달리 **로그인한 사람이 볼 수 있는 시트면 다 읽힌다.** 조직 제한
/// 시트를 "링크가 있는 모든 사용자" 로 풀지 않아도 되는 게 이 경로의 존재 이유다.
public struct GoogleSheetsAPI: Sendable {
    let accessToken: String
    let fetch: HTTPFetch

    static let base = "https://sheets.googleapis.com/v4/spreadsheets"

    public init(accessToken: String, fetch: @escaping HTTPFetch = performRequest) {
        self.accessToken = accessToken
        self.fetch = fetch
    }

    // MARK: 값 읽기

    /// 탭 하나를 행 × 열로 읽는다. `gid` 를 주면 그 탭, 없으면 첫 번째 탭.
    public func rows(spreadsheetID: String, gid: String?) throws -> [[String]] {
        let title = try sheetTitle(spreadsheetID: spreadsheetID, gid: gid)
        return try values(spreadsheetID: spreadsheetID, range: title)
    }

    /// gid 는 API 의 range 문법에 쓸 수 없어서 탭 이름으로 바꿔야 한다.
    func sheetTitle(spreadsheetID: String, gid: String?) throws -> String {
        var components = URLComponents(string: "\(Self.base)/\(spreadsheetID)")
        components?.queryItems = [URLQueryItem(name: "fields", value: "sheets.properties")]
        guard let url = components?.url else {
            throw StringsmithError.invalidConfiguration(
                path: spreadsheetID,
                reason: tr("Could not build the API URL.", "API 주소를 만들지 못했습니다."))
        }

        let body = try send(url)
        let document = try decode(Spreadsheet.self, from: body, url: url)
        let sheets = document.sheets.map(\.properties)
        guard !sheets.isEmpty else {
            throw StringsmithError.emptySheet(path: spreadsheetID)
        }

        guard let gid, let wanted = Int(gid) else {
            return sheets[0].title
        }
        guard let match = sheets.first(where: { $0.sheetId == wanted }) else {
            let names = sheets.map { "\($0.title) (gid=\($0.sheetId))" }.joined(separator: ", ")
            throw StringsmithError.invalidConfiguration(
                path: spreadsheetID,
                reason: tr(
                    """
                    No tab with gid=\(gid) in this spreadsheet.
                      Tabs found: \(names)
                    """,
                    """
                    이 스프레드시트에 gid=\(gid) 인 탭이 없습니다.
                      있는 탭: \(names)
                    """))
        }
        return match.title
    }

    func values(spreadsheetID: String, range: String) throws -> [[String]] {
        // 탭 이름에 공백이나 한글이 있어도 되도록 경로 성분을 인코딩한다.
        let encoded =
            range.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? range
        var components = URLComponents(string: "\(Self.base)/\(spreadsheetID)/values/\(encoded)")
        components?.queryItems = [
            URLQueryItem(name: "majorDimension", value: "ROWS"),
            // 화면에 보이는 문자열 그대로 받는다. 수식·숫자 서식을 CSV 내보내기와 맞춘다.
            URLQueryItem(name: "valueRenderOption", value: "FORMATTED_VALUE"),
        ]
        guard let url = components?.url else {
            throw StringsmithError.invalidConfiguration(
                path: spreadsheetID,
                reason: tr("Could not build the API URL.", "API 주소를 만들지 못했습니다."))
        }

        let body = try send(url)
        // 뒤쪽 빈 칸은 응답에서 통째로 빠진다. 행마다 길이가 달라도 되게 되어 있으므로 그대로 쓴다.
        return try decode(ValueRange.self, from: body, url: url).values ?? []
    }

    // MARK: 전송

    private func send(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response = try fetch(request)
        guard response.status == 200 else {
            throw StringsmithError.io(path: url.absoluteString, reason: Self.explain(response))
        }
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StringsmithError.io(
                path: url.absoluteString,
                reason: tr(
                    "Could not read the API response.", "API 응답을 해석하지 못했습니다."))
        }
    }

    /// 구글이 돌려주는 상태 코드를 무엇을 해야 하는지로 바꾼다.
    static func explain(_ response: SheetResponse) -> String {
        let message = (try? JSONDecoder().decode(APIError.self, from: response.body))?.error.message

        switch response.status {
        case 401:
            return tr(
                """
                The sign-in was rejected (401).
                  → Run: ss auth login
                """,
                """
                로그인이 거부되었습니다 (401).
                  → 실행: ss auth login
                """)
        case 403:
            return tr(
                """
                Your account cannot read this sheet (403).
                  → Ask the owner to share it with you, or sign in as an account that can:
                      ss auth login
                """,
                """
                이 계정으로는 시트를 읽을 수 없습니다 (403).
                  → 소유자에게 공유를 요청하거나, 읽을 수 있는 계정으로 로그인하세요:
                      ss auth login
                """)
        case 404:
            return tr(
                """
                No such spreadsheet (404).
                  → Check the URL or ID in the config.
                """,
                """
                그런 스프레드시트가 없습니다 (404).
                  → 설정의 URL 이나 ID 를 확인하세요.
                """)
        case 429:
            return tr(
                "Too many requests to Google (429). Wait a minute and try again.",
                "Google 요청이 너무 잦습니다 (429). 잠시 뒤 다시 시도하세요.")
        default:
            let detail = message.map { ": \($0)" } ?? ""
            return tr(
                "Google returned HTTP \(response.status)\(detail)",
                "Google 이 HTTP \(response.status) 를 돌려줬습니다\(detail)")
        }
    }

    // MARK: 응답 모델

    struct Spreadsheet: Decodable {
        struct Sheet: Decodable { let properties: Properties }
        struct Properties: Decodable {
            let sheetId: Int
            let title: String
        }
        let sheets: [Sheet]
    }

    struct ValueRange: Decodable {
        let values: [[String]]?
    }

    struct APIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
