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

/// `URLSession` 기본 구현.
///
/// CLI 는 동기 흐름이라 세마포어로 기다린다. `URLSession.shared` 는 완료를 자체 큐에서
/// 전달하므로 메인 스레드에서 기다려도 교착이 생기지 않는다.
public func downloadSheet(_ url: URL) throws -> SheetResponse {
    final class Box: @unchecked Sendable {
        var result: Result<SheetResponse, Error>?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    // 리다이렉트를 따라가야 한다 — Google 은 export 요청을 다른 호스트로 넘긴다.
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error {
            box.result = .failure(error)
            return
        }
        let http = response as? HTTPURLResponse
        box.result = .success(
            SheetResponse(
                status: http?.statusCode ?? 0,
                mimeType: http?.mimeType,
                body: data ?? Data()
            ))
    }
    task.resume()
    done.wait()

    switch box.result {
    case let .success(response): return response
    case let .failure(error): throw error
    case nil:
        throw StringsmithError.io(
            path: url.absoluteString,
            reason: tr("No response.", "응답을 받지 못했습니다."))
    }
}

// MARK: - Google Sheets 소스

public struct GoogleSheetsSource: SheetSource {
    public let url: String
    public let gid: String?
    /// 마지막으로 받은 내용을 둘 파일. 네트워크가 안 되면 이걸 쓴다.
    public let cachePath: String?
    let fetch: SheetFetch

    public init(url: String, gid: String? = nil, cachePath: String? = nil, fetch: @escaping SheetFetch = downloadSheet) {
        self.url = url
        self.gid = gid
        self.cachePath = cachePath
        self.fetch = fetch
    }

    public func rows() throws -> [[String]] {
        let text = try download()
        return CSVParser().parse(text)
    }

    /// 내려받아 캐시에 저장한다. 실패하면 캐시로 대체한다.
    func download() throws -> String {
        guard let ids = GoogleSheetsURL.identifiers(from: url) else {
            throw StringsmithError.invalidConfiguration(
                path: url,
                reason: tr(
                    "Not a Google Sheets URL. Expected https://docs.google.com/spreadsheets/d/…",
                    "Google Sheets 주소가 아닙니다. https://docs.google.com/spreadsheets/d/… 형태여야 합니다."))
        }
        guard let export = GoogleSheetsURL.exportURL(id: ids.id, gid: gid ?? ids.gid) else {
            throw StringsmithError.invalidConfiguration(
                path: url, reason: tr("Could not build the export URL.", "내보내기 주소를 만들지 못했습니다."))
        }

        do {
            let response = try fetch(export)
            let text = try validate(response, export: export)
            saveCache(text)
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
                  → Share it as "Anyone with the link can view",
                    or use a service account (see the README).
                """,
                """
                로그인 없이 읽을 수 없는 시트입니다 (HTTP \(response.status)).
                  → "링크가 있는 모든 사용자"로 공유하거나,
                    서비스 계정을 설정하세요 (README 참고).
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
