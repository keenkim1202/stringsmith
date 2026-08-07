import Foundation

// MARK: - 시트에서 읽어들인 한 줄

/// 로컬라이제이션 항목 하나. 시트의 한 행에 대응한다.
public struct LocalizationEntry: Sendable, Equatable {
    /// 문자열 키. 시트의 key 컬럼 값.
    public var key: String
    /// 화면·그룹 이름. 네임스페이스와 주석에 쓰인다. 선택.
    public var screen: String?
    /// 번역가·개발자용 설명. `.xcstrings`의 comment로 나간다. 선택.
    public var comment: String?
    /// 로케일 코드 → 번역 값.
    public var values: [String: String]
    /// 원본 시트에서의 행 번호(1-based). 오류 메시지에만 쓴다.
    public var sourceRow: Int

    public init(
        key: String,
        screen: String? = nil,
        comment: String? = nil,
        values: [String: String],
        sourceRow: Int = 0
    ) {
        self.key = key
        self.screen = screen
        self.comment = comment
        self.values = values
        self.sourceRow = sourceRow
    }
}

/// 시트 한 장(또는 여러 탭)을 읽어 만든 테이블.
public struct LocalizationTable: Sendable, Equatable {
    /// 원문 로케일. 이 값이 비어 있으면 오류로 취급한다.
    public var sourceLocale: String
    public var entries: [LocalizationEntry]

    public init(sourceLocale: String, entries: [LocalizationEntry]) {
        self.sourceLocale = sourceLocale
        self.entries = entries
    }

    /// 테이블에 등장하는 모든 로케일 코드 (정렬됨).
    public var locales: [String] {
        Set(entries.flatMap(\.values.keys)).sorted()
    }
}

// MARK: - 오류

/// 사용자에게 그대로 보여줄 수 있는 오류.
///
/// 메시지는 **무엇이 틀렸는지 + 어떻게 고치는지**를 함께 담는다.
/// 특히 컬럼 매핑 실패는 시트에 실제로 있는 컬럼 목록을 함께 보여준다.
public enum StringsmithError: Error, Sendable, Equatable {
    /// 매핑에 지정된 컬럼이 시트에 없음. 후보 제안을 포함한다.
    case columnNotFound(requested: String, role: String, available: [String], suggestion: String?)
    /// 시트가 비어 있거나 헤더 행을 찾지 못함.
    case emptySheet(path: String)
    /// 헤더 행 번호가 시트 범위를 벗어남.
    case headerRowOutOfRange(requested: Int, totalRows: Int)
    /// 같은 키가 두 번 이상 나타남.
    case duplicateKey(key: String, rows: [Int])
    /// 원문 로케일 값이 비어 있음.
    case emptySourceValue(key: String, locale: String, row: Int)
    /// 변수(플레이스홀더) 검증 실패. 모든 문제를 모아 한 번에 보여준다.
    case validationFailed(issues: [String])
    /// 설정 파일을 읽거나 해석할 수 없음.
    case invalidConfiguration(path: String, reason: String)
    /// 파일 입출력 실패.
    case io(path: String, reason: String)
}

extension StringsmithError: LocalizedError {
    /// CLI가 그대로 출력한다. `localizedDescription`으로도 같은 문장이 나온다.
    public var errorDescription: String? { description }
}

extension StringsmithError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .columnNotFound(requested, role, available, suggestion):
            var lines = [
                tr(
                    "Column \"\(requested)\" (\(role)) is not in the sheet.",
                    "컬럼 \"\(requested)\"(\(role))을(를) 찾을 수 없습니다."),
                tr(
                    "  Columns found: \(available.joined(separator: ", "))",
                    "  시트에 있는 컬럼: \(available.joined(separator: ", "))"),
            ]
            if let suggestion {
                lines.append(
                    tr("  → Did you mean \"\(suggestion)\"?", "  → \"\(suggestion)\"을(를) 의도하셨나요?"))
            }
            lines.append(
                tr("  → Fix columns.\(role) in the config.", "  → 설정의 columns.\(role) 항목을 수정하세요."))
            return lines.joined(separator: "\n")

        case let .emptySheet(path):
            return tr(
                "The sheet is empty or has no header: \(path)",
                "시트가 비어 있거나 헤더를 찾을 수 없습니다: \(path)")

        case let .headerRowOutOfRange(requested, totalRows):
            return tr(
                """
                Header row \(requested) is past the end of the sheet (\(totalRows) rows).
                  → Check source.headerRow in the config.
                """,
                """
                헤더 행 \(requested)이(가) 시트 범위를 벗어납니다 (전체 \(totalRows)행).
                  → 설정의 source.headerRow를 확인하세요.
                """)

        case let .duplicateKey(key, rows):
            let rowList = rows.map(String.init).joined(separator: ", ")
            return tr(
                """
                Key "\(key)" appears more than once (rows \(rowList)).
                  → Remove the duplicate rows, or make the keys distinct.
                """,
                """
                키 "\(key)"가 여러 번 나타납니다 (행 \(rowList)).
                  → 시트에서 중복 행을 제거하거나 키를 구분하세요.
                """)

        case let .emptySourceValue(key, locale, row):
            return tr(
                """
                Key "\(key)" has no source value (\(locale)) on row \(row).
                  → Without the source there is nothing to translate against.
                """,
                """
                키 "\(key)"의 원문(\(locale)) 값이 비어 있습니다 (행 \(row)).
                  → 원문이 없으면 번역의 기준이 없습니다. 시트를 채우세요.
                """)

        case let .validationFailed(issues):
            let header = tr(
                "Variable validation failed (\(issues.count)):",
                "변수 검증에 실패했습니다 (\(issues.count)건):")
            return ([header] + issues.map { "  ✗ \($0)" }).joined(separator: "\n")

        case let .invalidConfiguration(path, reason):
            return tr(
                "Could not read the config: \(path)\n  \(reason)",
                "설정 파일을 읽을 수 없습니다: \(path)\n  \(reason)")

        case let .io(path, reason):
            // 파일뿐 아니라 URL 에도 쓰이므로 중립적으로 적는다.
            return tr(
                "Could not read: \(path)\n  \(reason)",
                "읽지 못했습니다: \(path)\n  \(reason)")
        }
    }
}
