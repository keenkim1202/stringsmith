import Foundation
import Testing

@testable import StringsmithCore

@Suite("컬럼 매핑 추론")
struct MappingInferenceTests {

    @Test("한국어 헤더를 추론한다")
    func koreanHeaders() throws {
        let result = MappingInference.infer(
            headers: ["키", "화면", "설명", "한국어", "영어", "일본어"]
        )
        let mapping = try #require(result.mapping)
        #expect(mapping.key == "키")
        #expect(mapping.screen == "화면")
        #expect(mapping.description == "설명")
        #expect(mapping.languages == ["ko": "한국어", "en": "영어", "ja": "일본어"])
        #expect(result.unmapped.isEmpty)
    }

    @Test("영어 헤더를 추론한다")
    func englishHeaders() throws {
        let result = MappingInference.infer(headers: ["key", "Screen", "ko", "en"])
        let mapping = try #require(result.mapping)
        #expect(mapping.key == "key")
        #expect(mapping.screen == "Screen")
        #expect(mapping.languages == ["ko": "ko", "en": "en"])
    }

    @Test("괄호·공백·하이픈은 무시하고 맞춘다")
    func normalization() throws {
        let result = MappingInference.infer(headers: ["key", "중국어 (간체)", "zh-Hant"])
        let mapping = try #require(result.mapping)
        #expect(mapping.languages["zh-Hans"] == "중국어 (간체)")
        #expect(mapping.languages["zh-Hant"] == "zh-Hant")
    }

    @Test("모르는 컬럼은 unmapped로 보고한다 — 조용히 삼키지 않는다")
    func unmappedReported() {
        let result = MappingInference.infer(headers: ["키", "한국어", "상태", "담당자"])
        #expect(result.unmapped == ["상태", "담당자"])
    }

    @Test("키 컬럼이 없으면 실패 사유를 돌려준다")
    func missingKeyColumn() {
        let result = MappingInference.infer(headers: ["한국어", "영어"])
        #expect(result.mapping == nil)
        #expect(result.failureReason != nil)
    }

    @Test("언어 컬럼이 없으면 실패 사유를 돌려준다")
    func missingLanguageColumn() {
        let result = MappingInference.infer(headers: ["키", "화면"])
        #expect(result.mapping == nil)
        #expect(result.failureReason != nil)
    }
}

@Suite("헤더 조회와 오탈자 제안")
struct HeaderIndexTests {

    @Test("정확히 일치하면 인덱스를 돌려준다")
    func exactMatch() throws {
        let index = HeaderIndex(headers: ["키", "한국어", "영어"])
        #expect(try index.index(of: "한국어", role: "languages.ko") == 1)
    }

    @Test("대소문자·공백 차이는 흡수한다")
    func normalizedMatch() throws {
        let index = HeaderIndex(headers: ["Key", " Korean "])
        #expect(try index.index(of: "key", role: "key") == 0)
        #expect(try index.index(of: "korean", role: "languages.ko") == 1)
    }

    @Test("없는 컬럼은 실제 컬럼 목록과 제안을 담아 던진다")
    func notFoundIncludesAvailableColumns() {
        let index = HeaderIndex(headers: ["키", "Screen", "한국어"])
        #expect(throws: StringsmithError.self) {
            try index.index(of: "화면", role: "screen")
        }
        do {
            _ = try index.index(of: "Scren", role: "screen")
            Issue.record("던져야 한다")
        } catch let error as StringsmithError {
            guard case let .columnNotFound(_, _, available, suggestion) = error else {
                Issue.record("columnNotFound 여야 한다")
                return
            }
            #expect(available == ["키", "Screen", "한국어"])
            #expect(suggestion == "Screen")
        } catch {
            Issue.record("StringsmithError 여야 한다")
        }
    }

    @Test("무관한 이름에는 제안하지 않는다")
    func noSuggestionForUnrelated() {
        let index = HeaderIndex(headers: ["키", "한국어"])
        #expect(index.closestMatch(to: "완전히다른이름") == nil)
    }
}

@Suite("헤더 행 자동 감지")
struct HeaderDetectionTests {

    @Test("첫 행이 헤더면 1을 돌려준다")
    func firstRow() {
        let rows = [["키", "한국어", "영어"], ["a", "가", "A"]]
        #expect(MappingInference.detectHeaderRow(in: rows) == 1)
    }

    @Test("위에 제목·안내 행이 있어도 찾는다")
    func skipsPreamble() {
        let rows = [
            ["이 시트는 번역 관리용입니다"],
            ["최종 수정: 2026-08-07", "", ""],
            ["키", "화면", "한국어", "영어"],
            ["a", "설정", "가", "A"],
        ]
        #expect(MappingInference.detectHeaderRow(in: rows) == 3)
    }

    @Test("매핑이 더 많이 걸리는 행을 고른다")
    func picksRichestRow() {
        let rows = [
            ["키", "메모"],                       // 키만 있고 언어 없음 → 후보 아님
            ["키", "화면", "설명", "한국어", "영어"],  // 점수 최고
            ["a", "설정", "", "가", "A"],
        ]
        #expect(MappingInference.detectHeaderRow(in: rows) == 2)
    }

    @Test("헤더가 없으면 nil")
    func noHeader() {
        let rows = [["a", "b"], ["c", "d"]]
        #expect(MappingInference.detectHeaderRow(in: rows) == nil)
    }
}

@Suite("메시지 언어")
struct MessagesTests {

    @Test("시스템 선호 언어에서 고른다")
    func picksFromPreferredLanguages() {
        #expect(Messages.resolve(["ko-KR", "en-US"]) == .ko)
        #expect(Messages.resolve(["en-KR", "ko-KR"]) == .en)
        #expect(Messages.resolve(["ja-JP", "ko-KR"]) == .ko)  // ja 는 미지원 → 다음 후보
    }

    @Test("환경변수가 시스템 설정보다 우선한다")
    func overrideWins() {
        #expect(Messages.resolve(["en-US"], override: "ko") == .ko)
        #expect(Messages.resolve(["ko-KR"], override: "en") == .en)
        // 해석되지 않는 값은 무시한다
        #expect(Messages.resolve(["ko-KR"], override: "fr") == .ko)
    }

    @Test("지원하지 않는 언어만 있으면 영어로 떨어진다")
    func fallsBackToEnglish() {
        #expect(Messages.resolve(["fr-FR", "de-DE"]) == .en)
        #expect(Messages.resolve([]) == .en)
    }
}
