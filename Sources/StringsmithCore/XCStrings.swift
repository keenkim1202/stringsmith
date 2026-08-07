import Foundation

/// Xcode String Catalog(`.xcstrings`) 문서 모델.
///
/// 스키마는 Xcode 26 동봉 `xcstringstool`로 왕복 확인한 범위만 담는다.
/// 복수형(`variations`)·기기별 변형은 v0.2 이후에 추가한다.
public struct XCStringsDocument: Codable, Sendable, Equatable {
    public var sourceLanguage: String
    public var strings: [String: Entry]
    public var version: String

    public init(sourceLanguage: String, strings: [String: Entry], version: String = "1.0") {
        self.sourceLanguage = sourceLanguage
        self.strings = strings
        self.version = version
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var comment: String?
        /// 시트에서 온 키는 소스 추출물이 아니므로 항상 `manual`이다.
        /// 이 값이 있어야 Xcode가 자동 추출 때 stale로 지우지 않는다.
        public var extractionState: String?
        public var localizations: [String: Localization]?

        public init(
            comment: String? = nil,
            extractionState: String? = "manual",
            localizations: [String: Localization]? = nil
        ) {
            self.comment = comment
            self.extractionState = extractionState
            self.localizations = localizations
        }
    }

    public struct Localization: Codable, Sendable, Equatable {
        public var stringUnit: StringUnit
        public init(stringUnit: StringUnit) { self.stringUnit = stringUnit }
    }

    public struct StringUnit: Codable, Sendable, Equatable {
        public var state: String
        public var value: String
        public init(state: String = "translated", value: String) {
            self.state = state
            self.value = value
        }
    }
}

// MARK: - 변환

extension XCStringsDocument {
    /// 테이블을 문서로 변환한다.
    ///
    /// 값이 빈 문자열인 로케일은 **넣지 않는다.** 빈 값을 `translated`로 넣으면
    /// Xcode가 번역이 있는 것으로 간주해 누락이 감춰진다.
    public init(table: LocalizationTable) {
        var strings: [String: Entry] = [:]
        for entry in table.entries {
            var localizations: [String: Localization] = [:]
            for (locale, value) in entry.values where !value.isEmpty {
                localizations[locale] = Localization(stringUnit: StringUnit(value: value))
            }
            strings[entry.key] = Entry(
                comment: Self.comment(for: entry),
                extractionState: "manual",
                localizations: localizations.isEmpty ? nil : localizations
            )
        }
        self.init(sourceLanguage: table.sourceLocale, strings: strings)
    }

    /// 화면·설명 컬럼을 하나의 주석으로 합친다. 둘 다 없으면 주석을 넣지 않는다.
    static func comment(for entry: LocalizationEntry) -> String? {
        let parts = [entry.screen, entry.comment]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

// MARK: - 결정적 직렬화

public enum XCStringsWriter {
    /// 바이트 단위로 재현 가능한 JSON을 만든다.
    ///
    /// 생성물이 커밋되는 이상 비결정적 출력은 매 실행마다 머지 충돌을 만든다.
    /// `.sortedKeys`로 키 순서를 고정하고, 슬래시 이스케이프를 끄고, 끝에 개행을 붙인다.
    public static func data(for document: XCStringsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)  // 파일 끝 개행 — 없으면 git이 매번 diff를 만든다
        return data
    }

    /// 파일로 쓴다. 내용이 같으면 **쓰지 않는다** (mtime을 건드리면 불필요한 재빌드가 난다).
    /// - Returns: 실제로 파일이 바뀌었으면 `true`.
    @discardableResult
    public static func write(_ document: XCStringsDocument, to path: String) throws -> Bool {
        let data = try data(for: document)
        if let existing = FileManager.default.contents(atPath: path), existing == data {
            return false
        }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true
                )
            } catch {
                throw StringsmithError.io(path: directory, reason: tr("Could not create the directory.", "디렉터리를 만들 수 없습니다."))
            }
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw StringsmithError.io(path: path, reason: error.localizedDescription)
        }
        return true
    }
}
