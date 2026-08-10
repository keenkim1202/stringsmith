import Foundation

/// `.xlsx` 를 행 × 열로 읽는다.
///
/// 엑셀 파일은 XML 몇 개를 담은 ZIP 이다. 필요한 건 셋뿐이라 전체 규격을 구현하지 않는다:
///
/// - `xl/workbook.xml` — 시트 이름과 순서
/// - `xl/sharedStrings.xml` — 문자열 표. 셀은 여기 색인을 가리킨다
/// - `xl/worksheets/sheetN.xml` — 셀
///
/// **숫자 서식은 해석하지 않는다.** 엑셀에서 날짜는 일련번호로 저장되므로, 날짜 서식이
/// 걸린 칸은 `45870` 같은 값으로 읽힌다. 번역 시트에서 날짜를 키나 값으로 쓸 일이 없어
/// 그대로 두었다 — 서식 표까지 따라가면 읽어야 할 XML 이 둘 더 늘어난다.
public struct XLSXReader {

    let archive: ZipArchive

    public init(path: String) throws {
        archive = try ZipArchive(path: path)
        guard archive.contents(of: "xl/workbook.xml") != nil else {
            throw StringsmithError.io(
                path: path,
                reason: tr(
                    "Not an .xlsx workbook (xl/workbook.xml is missing).",
                    ".xlsx 통합 문서가 아닙니다 (xl/workbook.xml 이 없습니다)."))
        }
    }

    /// 통합 문서에 있는 시트 이름. 순서대로.
    public func sheetNames() -> [String] {
        guard let data = archive.contents(of: "xl/workbook.xml") else { return [] }
        return XMLScan.attributes(in: data, element: "sheet").compactMap { $0["name"] }
    }

    /// 시트 하나를 행 × 열로.
    ///
    /// - Parameter named: 시트 이름. 생략하면 첫 번째.
    public func rows(named: String? = nil) throws -> [[String]] {
        let names = sheetNames()
        let index: Int
        if let named {
            guard let found = names.firstIndex(of: named) else {
                throw StringsmithError.invalidConfiguration(
                    path: named,
                    reason: tr(
                        """
                        No sheet "\(named)" in this workbook.
                          Sheets found: \(names.joined(separator: ", "))
                        """,
                        """
                        이 통합 문서에 "\(named)" 시트가 없습니다.
                          있는 시트: \(names.joined(separator: ", "))
                        """))
            }
            index = found
        } else {
            index = 0
        }

        // 시트 파일 이름은 workbook.xml 의 순서와 반드시 같지는 않지만, 엑셀이 쓰는 파일은
        // 거의 언제나 sheet1.xml 부터 순서대로다. 없으면 있는 것 중 순서대로 집는다.
        let candidate = "xl/worksheets/sheet\(index + 1).xml"
        let sheetPath: String
        if archive.contents(of: candidate) != nil {
            sheetPath = candidate
        } else {
            let all = archive.names.filter {
                $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml")
            }.sorted()
            guard index < all.count else {
                throw StringsmithError.emptySheet(path: named ?? "sheet\(index + 1)")
            }
            sheetPath = all[index]
        }

        guard let sheet = archive.contents(of: sheetPath) else {
            throw StringsmithError.emptySheet(path: sheetPath)
        }
        return Self.cells(in: sheet, shared: sharedStrings())
    }

    /// 문자열 표. 셀이 `t="s"` 일 때 색인으로 여기를 가리킨다.
    func sharedStrings() -> [String] {
        guard let data = archive.contents(of: "xl/sharedStrings.xml") else { return [] }
        return XMLScan.sharedStrings(in: data)
    }

    // MARK: - 셀 읽기

    /// 시트 XML 을 행 × 열로.
    ///
    /// 빈 칸은 파일에 아예 없다. 셀의 `r="C5"` 를 보고 제자리에 넣어야 열이 밀리지 않는다.
    static func cells(in data: Data, shared: [String]) -> [[String]] {
        var rows: [[String]] = []
        for row in XMLScan.rows(in: data) {
            var line: [String] = []
            for cell in row {
                let column = columnIndex(of: cell.reference)
                // 빠진 칸을 채워 자리를 맞춘다.
                while line.count < column { line.append("") }

                let value: String
                switch cell.type {
                case "s":
                    let index = Int(cell.value) ?? -1
                    value = (index >= 0 && index < shared.count) ? shared[index] : ""
                case "inlineStr":
                    value = cell.inline
                default:
                    value = cell.value
                }
                if line.count == column {
                    line.append(value)
                } else {
                    line[column] = value
                }
            }
            rows.append(line)
        }
        // 뒤쪽 빈 행은 떨어낸다. 엑셀은 손댄 적 있는 행을 빈 채로 남겨 둔다.
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        return rows
    }

    /// `C5` → `2`. 열 이름은 26진수처럼 `A…Z, AA…` 로 늘어난다.
    static func columnIndex(of reference: String) -> Int {
        var index = 0
        for character in reference {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }
}
