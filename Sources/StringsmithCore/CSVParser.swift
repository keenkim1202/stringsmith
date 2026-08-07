import Foundation

/// RFC 4180 기반 구분자 텍스트 파서.
///
/// 실무 시트에서 실제로 나오는 것들을 처리한다:
/// - 따옴표로 감싼 필드 안의 구분자·개행
/// - `""` 이스케이프
/// - CRLF / LF / CR 혼용
/// - UTF-8 BOM
///
/// 의존성을 두지 않기 위해 직접 구현한다. XLSX는 v0.2에서 별도 소스로 추가한다.
public struct CSVParser: Sendable {
    public let delimiter: Character

    public init(delimiter: Character = ",") {
        self.delimiter = delimiter
    }

    /// 확장자로 구분자를 추정한다. `.tsv`는 탭, 그 외는 콤마.
    public static func forFile(at path: String) -> CSVParser {
        let ext = (path as NSString).pathExtension.lowercased()
        return CSVParser(delimiter: ext == "tsv" ? "\t" : ",")
    }

    /// 텍스트를 행 × 열 문자열 배열로 파싱한다.
    ///
    /// 행마다 열 개수가 다를 수 있다. 정규화는 호출자가 한다.
    public func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        // BOM 제거
        var scalars = Substring(text)
        if scalars.hasPrefix("\u{FEFF}") { scalars = scalars.dropFirst() }

        var iterator = scalars.makeIterator()
        var pending: Character? = nil

        func nextCharacter() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        func endField() {
            row.append(field)
            field = ""
        }

        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let ch = nextCharacter() {
            if inQuotes {
                if ch == "\"" {
                    // 다음 문자가 따옴표면 이스케이프된 따옴표
                    if let next = nextCharacter() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else if Self.isNewline(ch) {
                    // 따옴표 안의 개행은 값의 일부다. LF로 정규화한다.
                    field.append("\n")
                } else {
                    field.append(ch)
                }
                continue
            }

            switch ch {
            case "\"":
                inQuotes = true
            case delimiter:
                endField()
            case let ch where Self.isNewline(ch):
                endRow()
            default:
                field.append(ch)
            }
        }

        // 마지막 행: 내용이 있을 때만 추가한다 (파일 끝 개행으로 인한 빈 행 방지)
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }

        return rows
    }

    /// 개행 판정.
    ///
    /// - Important: Swift에서 `"\r\n"`은 **하나의 `Character`**(grapheme cluster)다.
    ///   `"\r"`이나 `"\n"`과 개별 비교하면 CRLF 파일이 통째로 한 필드가 된다.
    ///   Windows에서 저장한 CSV가 흔하므로 반드시 함께 본다.
    static func isNewline(_ ch: Character) -> Bool {
        ch == "\r\n" || ch == "\n" || ch == "\r"
    }

    /// 파일에서 읽어 파싱한다.
    public func parseFile(at path: String) throws -> [[String]] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StringsmithError.io(path: path, reason: tr("Could not read the file.", "파일을 읽을 수 없습니다."))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw StringsmithError.io(path: path, reason: tr("Not valid UTF-8.", "UTF-8로 디코딩할 수 없습니다."))
        }
        return parse(text)
    }
}

// MARK: - 행 유틸

extension Array where Element == [String] {
    /// 모든 셀이 빈 문자열(공백 포함)인 행을 제거한다.
    ///
    /// 실무 시트에는 구분용 빈 행이 늘 섞여 있다.
    func removingBlankRows() -> [[String]] {
        filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}
