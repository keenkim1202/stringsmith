import Foundation
import Testing

@testable import StringsmithCore

@Suite("CSV 파서")
struct CSVParserTests {

    @Test("기본 행·열 분리")
    func basic() {
        let rows = CSVParser().parse("key,ko,en\na,가,A\nb,나,B")
        #expect(rows == [["key", "ko", "en"], ["a", "가", "A"], ["b", "나", "B"]])
    }

    @Test("따옴표 안의 구분자는 필드를 나누지 않는다")
    func quotedDelimiter() {
        let rows = CSVParser().parse(#"key,value"# + "\n" + #"a,"안녕, 세계""#)
        #expect(rows[1] == ["a", "안녕, 세계"])
    }

    @Test("따옴표 안의 개행은 필드에 포함된다")
    func quotedNewline() {
        let rows = CSVParser().parse("key,value\na,\"첫 줄\n둘째 줄\"")
        #expect(rows.count == 2)
        #expect(rows[1][1] == "첫 줄\n둘째 줄")
    }

    @Test("이중 따옴표는 하나의 따옴표로 해석된다")
    func escapedQuote() {
        let rows = CSVParser().parse(#"a,"그는 ""안녕"" 이라 했다""#)
        #expect(rows[0][1] == #"그는 "안녕" 이라 했다"#)
    }

    @Test("CRLF와 LF를 모두 처리한다")
    func lineEndings() {
        let crlf = CSVParser().parse("a,b\r\nc,d\r\n")
        let lf = CSVParser().parse("a,b\nc,d\n")
        #expect(crlf == lf)
        #expect(crlf == [["a", "b"], ["c", "d"]])
    }

    @Test("따옴표 안의 CRLF는 LF로 정규화된다")
    func quotedCRLFNormalized() {
        let rows = CSVParser().parse("a,\"첫 줄\r\n둘째 줄\"")
        #expect(rows[0][1] == "첫 줄\n둘째 줄")
    }

    @Test("UTF-8 BOM을 제거한다")
    func bom() {
        let rows = CSVParser().parse("\u{FEFF}key,ko\na,가")
        #expect(rows[0][0] == "key")
    }

    @Test("파일 끝 개행이 빈 행을 만들지 않는다")
    func trailingNewline() {
        #expect(CSVParser().parse("a,b\n").count == 1)
    }

    @Test("TSV는 탭으로 나눈다")
    func tsv() {
        let rows = CSVParser(delimiter: "\t").parse("key\tko\na\t가, 나")
        #expect(rows[1] == ["a", "가, 나"])
    }

    @Test("확장자로 구분자를 고른다")
    func delimiterFromExtension() {
        #expect(CSVParser.forFile(at: "x/y.tsv").delimiter == "\t")
        #expect(CSVParser.forFile(at: "x/y.csv").delimiter == ",")
    }
}
