import Foundation

/// 시트 한 장을 행 × 열로 읽어오는 곳.
///
/// 로컬 파일과 Google Sheets 를 같은 자리에 꽂기 위한 경계다. XLSX·TMS 도 이 자리에 온다.
public protocol SheetSource: Sendable {
    /// 행 × 열. 행마다 열 개수가 달라도 된다 — 정규화는 호출자가 한다.
    func rows() throws -> [[String]]
}

// MARK: - 로컬 파일

public struct LocalFileSource: SheetSource {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func rows() throws -> [[String]] {
        try CSVParser.forFile(at: path).parseFile(at: path)
    }
}

// MARK: - Google Sheets URL

/// 공유 URL에서 시트 ID와 탭(gid)을 뽑아 CSV 내보내기 주소를 만든다.
public enum GoogleSheetsURL {
    /// 사용자가 붙여넣는 여러 형태를 받아준다.
    ///
    /// - `https://docs.google.com/spreadsheets/d/{ID}/edit#gid=0`
    /// - `https://docs.google.com/spreadsheets/d/{ID}/edit?gid=0#gid=0`
    /// - `https://docs.google.com/spreadsheets/d/{ID}`
    /// - `{ID}` 만 있는 경우
    public static func identifiers(from input: String) -> (id: String, gid: String?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let id: String
        if let range = trimmed.range(of: "/spreadsheets/d/") {
            let rest = trimmed[range.upperBound...]
            let candidate = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !candidate.isEmpty else { return nil }
            id = String(candidate)
        } else if !trimmed.contains("/"), !trimmed.contains(" ") {
            // URL 이 아니라 ID 만 붙여넣은 경우
            id = trimmed
        } else {
            return nil
        }

        // gid 는 쿼리(`?gid=`)에도 프래그먼트(`#gid=`)에도 올 수 있다.
        var gid: String? = nil
        if let range = trimmed.range(of: "gid=", options: .backwards) {
            let digits = trimmed[range.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { gid = String(digits) }
        }
        return (id, gid)
    }

    /// CSV 내보내기 주소. `gid` 를 주면 그 탭만 받는다.
    public static func exportURL(id: String, gid: String?) -> URL? {
        var components = URLComponents(
            string: "https://docs.google.com/spreadsheets/d/\(id)/export")
        var items = [URLQueryItem(name: "format", value: "csv")]
        if let gid { items.append(URLQueryItem(name: "gid", value: gid)) }
        components?.queryItems = items
        return components?.url
    }
}

// MARK: - 내려받기

/// HTTP 응답. 네트워크 계층을 갈아끼울 수 있게 최소한만 담는다.
public struct SheetResponse: Sendable {
    public var status: Int
    public var mimeType: String?
    public var body: Data

    public init(status: Int, mimeType: String?, body: Data) {
        self.status = status
        self.mimeType = mimeType
        self.body = body
    }
}

/// URL 하나를 받아 응답을 돌려준다. 테스트에서는 가짜 구현을 넣는다.
public typealias SheetFetch = @Sendable (URL) throws -> SheetResponse

/// 시트 하나를 내려받는다. 실제 전송은 `performRequest` 가 한다.
public func downloadSheet(_ url: URL) throws -> SheetResponse {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    // 리다이렉트를 따라가야 한다 — Google 은 export 요청을 다른 호스트로 넘긴다.
    return try performRequest(request)
}

// MARK: - Google Sheets 소스

public struct GoogleSheetsSource: SheetSource {
    public let url: String
    public let gid: String?
    /// 이어 붙일 탭 목록. 비어 있으면 `gid` 하나만 읽는다.
    public let tabs: [String]
    /// 헤더 행 번호(1-based). 탭을 이어 붙일 때 헤더를 맞춰 보고 건너뛰는 데 쓴다.
    public let headerRow: Int
    /// 마지막으로 받은 내용을 둘 파일. 네트워크가 안 되면 이걸 쓴다.
    public let cachePath: String?
    let fetch: SheetFetch
    /// 로그인 토큰이 있으면 Sheets API 로, 없으면 공개 CSV 내보내기로 읽는다.
    let tokens: TokenStore?
    let authorized: HTTPFetch

    public init(
        url: String,
        gid: String? = nil,
        tabs: [String] = [],
        headerRow: Int = 1,
        cachePath: String? = nil,
        tokens: TokenStore? = nil,
        fetch: @escaping SheetFetch = downloadSheet,
        authorized: @escaping HTTPFetch = performRequest
    ) {
        self.url = url
        self.gid = gid
        self.tabs = tabs
        self.headerRow = headerRow
        self.cachePath = cachePath
        self.tokens = tokens
        self.fetch = fetch
        self.authorized = authorized
    }

    public func rows() throws -> [[String]] {
        guard tabs.count > 1 else {
            return try rows(tab: tabs.first ?? gid)
        }
        return try merged()
    }

    /// 탭 하나를 읽는다. 로그인되어 있으면 API 로, 아니면 공개 링크로.
    func rows(tab: String?) throws -> [[String]] {
        if let rows = try authorizedRows(tab: tab) { return rows }
        return CSVParser().parse(try download(tab: tab))
    }

    /// 여러 탭을 위에서 아래로 이어 붙인다.
    ///
    /// 화면·도메인별로 탭을 나눠 둔 시트가 흔하다. 헤더가 서로 다르면 이어 붙이는 순간
    /// 열이 어긋나므로, 붙이기 전에 대조해서 다르면 멈춘다 — 조용히 섞이는 것보다 낫다.
    func merged() throws -> [[String]] {
        var out: [[String]] = []
        var header: [String]?
        var headerTab = ""

        for tab in tabs {
            let rows = try rows(tab: tab)
            let headerIndex = headerRow - 1
            // 빈 탭은 건너뛴다. 아직 안 채운 탭이 섞여 있는 건 흔한 일이다.
            guard rows.count > headerIndex else { continue }

            guard let first = header else {
                header = rows[headerIndex]
                headerTab = tab
                // 첫 탭은 헤더 위 안내 행까지 통째로 넘긴다 — headerRow 가 그대로 맞아야 한다.
                out = rows
                continue
            }
            guard normalize(rows[headerIndex]) == normalize(first) else {
                throw StringsmithError.invalidConfiguration(
                    path: url,
                    reason: tr(
                        """
                        Tabs have different columns, so they cannot be joined.
                          "\(headerTab)": \(first.joined(separator: ", "))
                          "\(tab)": \(rows[headerIndex].joined(separator: ", "))
                          → Make the header rows match, or list one tab at a time.
                        """,
                        """
                        탭마다 컬럼이 달라 이어 붙일 수 없습니다.
                          "\(headerTab)": \(first.joined(separator: ", "))
                          "\(tab)": \(rows[headerIndex].joined(separator: ", "))
                          → 헤더 행을 맞추거나, 탭을 하나씩 지정하세요.
                        """))
            }
            out += rows[(headerIndex + 1)...]
        }
        return out
    }

    /// 헤더 비교용. 앞뒤 공백과 뒤쪽 빈 칸은 차이로 치지 않는다 —
    /// 시트에서 뒤쪽 빈 칸은 응답에 아예 실리지 않아 탭마다 길이가 달라진다.
    func normalize(_ header: [String]) -> [String] {
        var trimmed = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed
    }

    /// 로그인되어 있을 때만 API 경로를 탄다. 아니면 nil 을 돌려 공개 링크로 넘긴다.
    ///
    /// 로그인을 강제하지 않는 건 의도한 것이다 — 공개 시트를 쓰는 사람은 지금까지처럼
    /// 아무 설정 없이 계속 쓸 수 있어야 한다.
    func authorizedRows(tab: String?) throws -> [[String]]? {
        guard let tokens, (try? tokens.load()) != nil else { return nil }
        guard let ids = GoogleSheetsURL.identifiers(from: url) else { return nil }

        let oauth = GoogleOAuth(fetch: authorized)
        let token = try oauth.validAccessToken(store: tokens)
        let api = GoogleSheetsAPI(accessToken: token, fetch: authorized)
        let rows = try api.rows(spreadsheetID: ids.id, gid: tab ?? gid ?? ids.gid)
        // 탭 하나만 읽을 때만 캐시한다. 이어 붙이는 경우는 조각을 남겨 봐야 못 쓴다.
        if tabs.count <= 1 { saveCache(CSVParser.serialize(rows)) }
        return rows
    }

    /// 내려받아 캐시에 저장한다. 실패하면 캐시로 대체한다.
    func download(tab: String?) throws -> String {
        guard let ids = GoogleSheetsURL.identifiers(from: url) else {
            throw StringsmithError.invalidConfiguration(
                path: url,
                reason: tr(
                    "Not a Google Sheets URL. Expected https://docs.google.com/spreadsheets/d/…",
                    "Google Sheets 주소가 아닙니다. https://docs.google.com/spreadsheets/d/… 형태여야 합니다."))
        }
        // 공개 링크는 gid 로만 탭을 고를 수 있다. 이름을 gid 로 바꾸려면 API 가 필요하다.
        if let tab, Int(tab) == nil {
            throw StringsmithError.invalidConfiguration(
                path: url,
                reason: tr(
                    """
                    Tab "\(tab)" is a name, and names only work when signed in.
                      → Use its gid, or run: ss auth login
                    """,
                    """
                    탭 "\(tab)" 은 이름인데, 이름은 로그인했을 때만 쓸 수 있습니다.
                      → gid 를 쓰거나, 실행: ss auth login
                    """))
        }
        guard let export = GoogleSheetsURL.exportURL(id: ids.id, gid: tab ?? gid ?? ids.gid) else {
            throw StringsmithError.invalidConfiguration(
                path: url, reason: tr("Could not build the export URL.", "내보내기 주소를 만들지 못했습니다."))
        }

        do {
            let response = try fetch(export)
            let text = try validate(response, export: export)
            if tabs.count <= 1 { saveCache(text) }
            return text
        } catch {
            // 네트워크가 끊겼을 때 캐시로 계속 갈 수 있어야 한다. 비행기·사내망에서 빌드가 멈추면 곤란하다.
            if let cached = loadCache() {
                FileHandle.standardError.write(
                    Data(
                        (tr(
                            "⚠️ Could not reach the sheet — using the cached copy.\n",
                            "⚠️ 시트를 가져오지 못해 캐시를 사용합니다.\n")).utf8))
                return cached
            }
            throw error
        }
    }

    /// 응답이 정말 CSV 인지 본다.
    ///
    /// 비공개 시트는 **404 와 `text/html`**(로그인 안내 페이지)을 돌려준다. 그대로 파싱하면
    /// "컬럼을 찾을 수 없다" 같은 엉뚱한 오류가 나므로 여기서 걸러 제대로 안내한다.
    func validate(_ response: SheetResponse, export: URL) throws -> String {
        let looksLikeHTML =
            (response.mimeType?.contains("html") ?? false)
            || String(decoding: response.body.prefix(64), as: UTF8.self)
                .lowercased().contains("<!doctype html")

        if response.status == 200, !looksLikeHTML {
            guard let text = String(data: response.body, encoding: .utf8) else {
                throw StringsmithError.io(
                    path: export.absoluteString,
                    reason: tr("The response is not valid UTF-8.", "응답을 UTF-8로 읽을 수 없습니다."))
            }
            return text
        }

        throw StringsmithError.io(
            path: export.absoluteString,
            reason: tr(
                """
                The sheet is not readable without signing in (HTTP \(response.status)).
                  → Sign in, and any sheet your account can open becomes readable:
                      ss auth login
                  → Or share it as "Anyone with the link can view".
                """,
                """
                로그인 없이 읽을 수 없는 시트입니다 (HTTP \(response.status)).
                  → 로그인하면 내 계정으로 열 수 있는 시트는 전부 읽힙니다:
                      ss auth login
                  → 또는 "링크가 있는 모든 사용자"로 공유하세요.
                """))
    }

    // MARK: 캐시

    func loadCache() -> String? {
        guard let cachePath, let data = FileManager.default.contents(atPath: cachePath) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveCache(_ text: String) {
        guard let cachePath else { return }
        let directory = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: cachePath))
    }
}
