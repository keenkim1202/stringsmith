import Foundation
import Testing

@testable import StringsmithCore

@Suite("Google Sheets URL 해석")
struct GoogleSheetsURLTests {

    @Test("공유 URL 에서 ID 와 gid 를 뽑는다")
    func parsesShareURL() throws {
        let ids = try #require(
            GoogleSheetsURL.identifiers(
                from: "https://docs.google.com/spreadsheets/d/ABC123xyz/edit#gid=42"))
        #expect(ids.id == "ABC123xyz")
        #expect(ids.gid == "42")
    }

    @Test("gid 가 쿼리에 있어도 찾는다")
    func gidInQuery() throws {
        let ids = try #require(
            GoogleSheetsURL.identifiers(
                from: "https://docs.google.com/spreadsheets/d/ABC/edit?gid=7#gid=7"))
        #expect(ids.id == "ABC")
        #expect(ids.gid == "7")
    }

    @Test("gid 가 없으면 nil")
    func noGid() throws {
        let ids = try #require(
            GoogleSheetsURL.identifiers(from: "https://docs.google.com/spreadsheets/d/ABC/edit"))
        #expect(ids.id == "ABC")
        #expect(ids.gid == nil)
    }

    @Test("ID 만 붙여넣어도 받는다")
    func bareIdentifier() throws {
        let ids = try #require(GoogleSheetsURL.identifiers(from: "1a2b3c"))
        #expect(ids.id == "1a2b3c")
    }

    @Test("Google Sheets 주소가 아니면 nil")
    func rejectsOtherURLs() {
        #expect(GoogleSheetsURL.identifiers(from: "https://example.com/a/b") == nil)
        #expect(GoogleSheetsURL.identifiers(from: "") == nil)
    }

    @Test("CSV 내보내기 주소를 만든다")
    func buildsExportURL() throws {
        let url = try #require(GoogleSheetsURL.exportURL(id: "ABC", gid: "5"))
        #expect(url.absoluteString == "https://docs.google.com/spreadsheets/d/ABC/export?format=csv&gid=5")
        let noGid = try #require(GoogleSheetsURL.exportURL(id: "ABC", gid: nil))
        #expect(noGid.absoluteString == "https://docs.google.com/spreadsheets/d/ABC/export?format=csv")
    }
}

@Suite("Google Sheets 내려받기")
struct GoogleSheetsSourceTests {

    private func source(
        _ response: @escaping @Sendable (URL) throws -> SheetResponse,
        cachePath: String? = nil
    ) -> GoogleSheetsSource {
        GoogleSheetsSource(
            url: "https://docs.google.com/spreadsheets/d/ABC/edit#gid=0",
            cachePath: cachePath,
            fetch: response
        )
    }

    private func csv(_ text: String) -> SheetResponse {
        SheetResponse(status: 200, mimeType: "text/csv", body: Data(text.utf8))
    }

    @Test("CSV 응답을 행으로 파싱한다")
    func parsesCSV() throws {
        let rows = try source { _ in self.csv("key,ko\na,가\n") }.rows()
        #expect(rows == [["key", "ko"], ["a", "가"]])
    }

    @Test("비공개 시트는 HTML 을 돌려준다 — CSV 로 파싱하지 않고 안내한다")
    func detectsSignInPage() {
        // Google 은 접근 불가 시트에 404 + text/html 을 준다 (2026-08-07 확인).
        let html = SheetResponse(
            status: 404, mimeType: "text/html",
            body: Data("<!DOCTYPE html><html><head>…".utf8))
        #expect(throws: StringsmithError.self) { try source { _ in html }.rows() }
    }

    @Test("200 이어도 본문이 HTML 이면 거른다")
    func detectsHTMLBodyWithOKStatus() {
        let html = SheetResponse(
            status: 200, mimeType: nil,
            body: Data("<!doctype html><html>".utf8))
        #expect(throws: StringsmithError.self) { try source { _ in html }.rows() }
    }

    @Test("성공하면 캐시에 남긴다")
    func writesCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-cache-\(UUID().uuidString)")
        let cache = directory.appendingPathComponent("sheet.csv").path
        _ = try source({ _ in self.csv("key,ko\na,가\n") }, cachePath: cache).rows()
        #expect(FileManager.default.fileExists(atPath: cache))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("네트워크가 실패하면 캐시로 계속 간다 — 사내망·비행기에서 빌드가 멈추면 곤란하다")
    func fallsBackToCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("sheet.csv").path
        try Data("key,ko\ncached,캐시\n".utf8).write(to: URL(fileURLWithPath: cache))

        // 실제로 오프라인이면 URLSession 이 URLError 를 던진다.
        let offline = URLError(.notConnectedToInternet)
        let rows = try source({ _ in throw offline }, cachePath: cache).rows()
        #expect(rows == [["key", "ko"], ["cached", "캐시"]])
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("캐시도 없으면 오류를 그대로 올린다")
    func failsWithoutCache() {
        #expect(throws: (any Error).self) {
            try source({ _ in throw URLError(.notConnectedToInternet) }).rows()
        }
    }

    /// 시트가 비공개로 바뀐 걸 캐시로 덮으면, 지워진 시트를 몇 달째 쓰고 있어도 모른다.
    @Test("접근이 막힌 것은 캐시로 덮지 않는다")
    func doesNotMaskAccessFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("sheet.csv").path
        try Data("key,ko\ncached,캐시\n".utf8).write(to: URL(fileURLWithPath: cache))
        defer { try? FileManager.default.removeItem(at: directory) }

        // 구글이 응답은 했다 — 로그인 안내 페이지로.
        let denied = SheetResponse(
            status: 404, mimeType: "text/html", body: Data("<!doctype html>".utf8))
        #expect(throws: StringsmithError.self) {
            try source({ _ in denied }, cachePath: cache).rows()
        }
    }
}
