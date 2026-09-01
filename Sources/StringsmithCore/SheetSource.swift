import Foundation

/// 시트 한 장을 행 × 열로 읽어오는 곳.
///
/// 로컬 파일과 Google Sheets 를 같은 자리에 꽂기 위한 경계다. XLSX·TMS 도 이 자리에 온다.
public protocol SheetSource: Sendable {
    /// 행 × 열과, 각 행이 원래 어디에 있었는지.
    func contents() throws -> SheetContents
}

extension SheetSource {
    /// 출처가 필요 없을 때 쓰는 지름길.
    public func rows() throws -> [[String]] { try contents().rows }
}

/// 시트에서 읽어들인 것.
public struct SheetContents: Sendable, Equatable {
    /// 행 × 열. 행마다 열 개수가 달라도 된다 — 정규화는 호출자가 한다.
    public var rows: [[String]]
    /// `rows` 와 길이가 같다. 탭을 이어 붙였을 때만 채운다.
    ///
    /// 이어 붙인 표의 102행이 두 번째 탭의 2행일 수 있다. 이걸 들고 다니지 않으면
    /// 오류가 가리키는 행을 사람이 찾아갈 수 없다.
    public var origins: [SheetOrigin]

    public init(rows: [[String]], origins: [SheetOrigin] = []) {
        self.rows = rows
        self.origins = origins
    }

    /// 병합본의 인덱스(0-based)를 원래 자리로 바꾼다.
    public func origin(at index: Int) -> SheetOrigin? {
        index < origins.count ? origins[index] : nil
    }
}

/// 어느 탭 몇 행이었는지.
public struct SheetOrigin: Sendable, Equatable, Codable {
    public var tab: String
    /// 그 탭에서의 행 번호(1-based).
    public var row: Int

    public init(tab: String, row: Int) {
        self.tab = tab
        self.row = row
    }
}

// MARK: - 로컬 파일

public struct LocalFileSource: SheetSource {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func contents() throws -> SheetContents {
        SheetContents(rows: try CSVParser.forFile(at: path).parseFile(at: path))
    }
}

// MARK: - 엑셀 파일

public struct XLSXSource: SheetSource {
    public let path: String
    /// 읽을 시트 이름. 없으면 첫 번째.
    public let sheet: String?

    public init(path: String, sheet: String? = nil) {
        self.path = path
        self.sheet = sheet
    }

    public func contents() throws -> SheetContents {
        SheetContents(rows: try XLSXReader(path: path).rows(named: sheet))
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

    public func contents() throws -> SheetContents {
        // 캐시는 모든 경로가 지나는 여기서 다룬다. 오프라인에서 견디는 힘이 로그인
        // 여부에 따라 달라질 이유가 없다.
        do {
            let contents = tabs.count > 1
                ? try merged()
                : SheetContents(rows: try rows(tab: tabs.first ?? gid))
            saveCache(contents)
            return contents
        } catch {
            // 망이 안 될 때만 캐시로 간다. 시트가 비공개로 바뀐 것(403)까지 캐시로 덮으면
            // 지워진 시트를 몇 달째 쓰고 있어도 아무도 모른다.
            guard Self.isTransportFailure(error), let cached = loadCache() else { throw error }

            // 캐시가 언제 것인지 함께 알린다. 나이를 모르면 몇 달 전 시트로 빌드하고도
            // 아무도 눈치채지 못한다.
            let age = cacheAge().map { " (\($0))" } ?? ""
            FileHandle.standardError.write(
                Data(
                    tr(
                        "⚠️ Could not reach the sheet, using the cached copy\(age).\n",
                        "⚠️ 시트를 가져오지 못해 캐시를 사용합니다\(age).\n").utf8))
            return cached
        }
    }

    /// 망 자체가 안 되는 경우인가.
    ///
    /// `URLError` 는 연결·DNS·시간 초과다. 우리가 던진 `.io` 는 구글이 응답은 했는데 그
    /// 내용이 문제인 경우(403·404·로그인 페이지)라서 캐시로 덮으면 안 된다.
    static func isTransportFailure(_ error: Error) -> Bool {
        error is URLError
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
    func merged() throws -> SheetContents {
        var out: [[String]] = []
        var origins: [SheetOrigin] = []
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
                origins = rows.indices.map { SheetOrigin(tab: tab, row: $0 + 1) }
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
            origins += rows.indices.dropFirst(headerIndex + 1).map {
                SheetOrigin(tab: tab, row: $0 + 1)
            }
        }
        return SheetContents(rows: out, origins: origins)
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
        return try api.rows(spreadsheetID: ids.id, gid: tab ?? gid ?? ids.gid)
    }

    /// 공개 CSV 내보내기로 받는다. 캐시는 `contents()` 가 다룬다.
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

        return try validate(try fetch(export), export: export)
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

    /// 캐시된 내용. 탭을 이어 붙인 것이면 출처까지 함께 돌려준다.
    func loadCache() -> SheetContents? {
        guard let cachePath, let data = FileManager.default.contents(atPath: cachePath),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        // 출처가 없으면 행 번호만 남는다 — 오프라인에서 오류가 `errors!2` 대신 `4` 를
        // 가리키게 되는데, 하필 그때가 사람이 시트를 열어 보기 어려운 순간이다.
        let origins =
            FileManager.default.contents(atPath: Self.originsPath(for: cachePath))
            .flatMap { try? JSONDecoder().decode([SheetOrigin].self, from: $0) } ?? []

        let rows = CSVParser().parse(text)
        // 길이가 어긋나면 서로 다른 시점의 파일이다. 틀린 위치를 대느니 안 대는 게 낫다.
        return SheetContents(rows: rows, origins: origins.count == rows.count ? origins : [])
    }

    static func originsPath(for cachePath: String) -> String { cachePath + ".origins.json" }

    /// 캐시 파일이 언제 것인지. 파일이 없거나 시각을 읽지 못하면 nil.
    func cacheAge() -> String? {
        guard let cachePath,
            let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Self.ageLabel(from: modified)
    }

    /// 날짜 대신 며칠 전인지로 적는다. 오래됐다는 사실만 눈에 들어오면 된다.
    static func ageLabel(from modified: Date, now: Date = Date()) -> String {
        let days = Calendar.current.dateComponents([.day], from: modified, to: now).day ?? 0
        if days < 1 { return tr("today", "오늘") }
        return tr("\(days) day(s) ago", "\(days)일 전")
    }

    func saveCache(_ contents: SheetContents) {
        guard let cachePath else { return }
        let directory = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try? Data(CSVParser.serialize(contents.rows).utf8)
            .write(to: URL(fileURLWithPath: cachePath))

        let sidecar = URL(fileURLWithPath: Self.originsPath(for: cachePath))
        if contents.origins.isEmpty {
            // 탭 하나짜리로 바뀌었는데 예전 출처가 남아 있으면 엉뚱한 탭을 가리킨다.
            try? FileManager.default.removeItem(at: sidecar)
        } else if let data = try? JSONEncoder().encode(contents.origins) {
            try? data.write(to: sidecar)
        }
    }
}
