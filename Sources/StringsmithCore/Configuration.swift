import Foundation

/// `.stringsmith.json` 설정.
///
/// - Note: 제안서 §14는 TOML을 상정했으나, v0.1은 **의존성 0**을 지키기 위해 JSON을 쓴다.
///   Swift에 표준 TOML 파서가 없어 외부 패키지가 필요하기 때문이다. TOML 지원은
///   설정 스키마가 안정된 뒤 v0.2 이후에 검토한다.
public struct Configuration: Codable, Sendable, Equatable {
    public var source: SourceConfig
    public var columns: ColumnMapping
    public var output: OutputConfig
    /// 변수 표기 처리. 생략하면 기본값(apple + brace, auto 위치 지정자).
    public var placeholders: PlaceholderConfig

    public init(
        source: SourceConfig,
        columns: ColumnMapping,
        output: OutputConfig,
        placeholders: PlaceholderConfig = PlaceholderConfig()
    ) {
        self.source = source
        self.columns = columns
        self.output = output
        self.placeholders = placeholders
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceConfig.self, forKey: .source)
        columns = try c.decode(ColumnMapping.self, forKey: .columns)
        output = try c.decode(OutputConfig.self, forKey: .output)
        placeholders =
            try c.decodeIfPresent(PlaceholderConfig.self, forKey: .placeholders)
            ?? PlaceholderConfig()
    }
}

public struct SourceConfig: Codable, Sendable, Equatable {
    /// `csv`(TSV 포함) 또는 `google-sheets`.
    public var type: String
    /// `csv` 일 때 시트 파일 경로. 설정 파일 위치 기준 상대 경로 또는 절대 경로.
    public var path: String
    /// `google-sheets` 일 때 공유 URL. 시트 ID 만 적어도 된다.
    public var url: String?
    /// 탭 식별자. URL 에 `gid=` 가 있으면 생략해도 된다.
    public var gid: String?
    /// 여러 탭을 이어 붙일 때 쓸 탭 목록. gid 또는 탭 이름.
    ///
    /// 화면·도메인별로 탭을 나눠 둔 시트가 흔하다. 비워 두면 `gid` 하나만 읽는다.
    /// 공개 링크로 읽을 때는 **gid 만** 쓸 수 있다 — 이름을 gid 로 바꾸려면 API 가 필요하다.
    public var tabs: [String]?
    /// 헤더가 있는 행 번호(1-based). 시트 위쪽에 제목·안내 행이 있는 경우가 많다.
    public var headerRow: Int
    /// 원문 로케일. `.xcstrings`의 sourceLanguage가 된다.
    public var defaultLocale: String

    public init(
        type: String = "csv",
        path: String = "",
        url: String? = nil,
        gid: String? = nil,
        tabs: [String]? = nil,
        headerRow: Int = 1,
        defaultLocale: String
    ) {
        self.type = type
        self.path = path
        self.url = url
        self.gid = gid
        self.tabs = tabs
        self.headerRow = headerRow
        self.defaultLocale = defaultLocale
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "csv"
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        gid = try c.decodeIfPresent(String.self, forKey: .gid)
        tabs = try c.decodeIfPresent([String].self, forKey: .tabs)
        headerRow = try c.decodeIfPresent(Int.self, forKey: .headerRow) ?? 1
        defaultLocale = try c.decode(String.self, forKey: .defaultLocale)
    }
}

public struct OutputConfig: Codable, Sendable, Equatable {
    /// 무엇을 만들지 고른다: `xcstrings` · `swift`.
    ///
    /// CLI의 `--only` 로 실행 단위 덮어쓰기가 가능하다.
    public var artifacts: [String]
    /// `.xcstrings`·`L10n.swift` 를 쓸 디렉터리. 보통 앱의 리소스 폴더다.
    public var path: String
    /// 테이블 이름. `Localizable.xcstrings`의 앞부분이 된다.
    public var tableName: String
    /// Swift 접근자 생성 옵션.
    public var swift: SwiftCodegen.Options

    public init(
        artifacts: [String] = ["xcstrings", "swift"],
        path: String,
        tableName: String = "Localizable",
        swift: SwiftCodegen.Options = SwiftCodegen.Options()
    ) {
        self.artifacts = artifacts
        self.path = path
        self.tableName = tableName
        self.swift = swift
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `formats` 는 예전 이름이다. 기존 설정 파일을 깨뜨리지 않는다.
        let legacy = try c.decodeIfPresent([String].self, forKey: .formats)
        artifacts =
            try c.decodeIfPresent([String].self, forKey: .artifacts)
            ?? legacy
            ?? ["xcstrings", "swift"]
        path = try c.decode(String.self, forKey: .path)
        tableName = try c.decodeIfPresent(String.self, forKey: .tableName) ?? "Localizable"
        swift =
            try c.decodeIfPresent(SwiftCodegen.Options.self, forKey: .swift)
            ?? SwiftCodegen.Options()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(path, forKey: .path)
        try c.encode(tableName, forKey: .tableName)
        try c.encode(swift, forKey: .swift)
    }

    enum CodingKeys: String, CodingKey {
        case artifacts, path, tableName, swift
        case formats  // 레거시
    }
}

// MARK: - 입출력

extension Configuration {
    public static let defaultFileName = ".stringsmith.json"

    /// 현재 디렉터리에서 위로 올라가며 설정 파일을 찾는다.
    ///
    /// git이 `.git`을 찾는 방식과 같다. 저장소 어느 하위 디렉터리에서 실행하든
    /// `--config`를 붙이지 않아도 되게 한다.
    ///
    /// - Returns: 찾은 설정 파일 경로. 없으면 `nil`.
    public static func discover(from directory: String? = nil) -> String? {
        var current = directory ?? FileManager.default.currentDirectoryPath
        while true {
            let candidate = (current as NSString).appendingPathComponent(defaultFileName)
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    public static func load(from path: String) throws -> Configuration {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StringsmithError.invalidConfiguration(
                path: path,
                reason: tr(
                    "No such file. Run `stringsmith init` to create one.",
                    "파일이 없습니다. `stringsmith init`으로 만들 수 있습니다.")
            )
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch let error as DecodingError {
            throw StringsmithError.invalidConfiguration(path: path, reason: Self.explain(error))
        } catch {
            throw StringsmithError.invalidConfiguration(path: path, reason: error.localizedDescription)
        }
    }

    /// 사람이 읽고 고칠 것을 전제로 정렬·들여쓰기를 고정해 쓴다.
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `DecodingError`를 사용자가 고칠 수 있는 문장으로 바꾼다.
    static func explain(_ error: DecodingError) -> String {
        func pathString(_ codingPath: [any CodingKey]) -> String {
            codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            let parent = pathString(context.codingPath)
            let full = parent.isEmpty ? key.stringValue : "\(parent).\(key.stringValue)"
            return tr(
                "Required field \"\(full)\" is missing.",
                "필수 항목 \"\(full)\"이(가) 없습니다.")
        case let .typeMismatch(_, context):
            let path = pathString(context.codingPath)
            return tr(
                "\"\(path)\" has the wrong type.",
                "\"\(path)\"의 값 타입이 맞지 않습니다.")
        case let .valueNotFound(_, context):
            let path = pathString(context.codingPath)
            return tr(
                "\"\(path)\" is empty.",
                "\"\(path)\"의 값이 비어 있습니다.")
        case let .dataCorrupted(context):
            let path = pathString(context.codingPath)
            return path.isEmpty
                ? tr(
                    "The JSON is malformed. \(context.debugDescription)",
                    "JSON 형식이 올바르지 않습니다. \(context.debugDescription)")
                : tr(
                    "The JSON is malformed near \"\(path)\".",
                    "\"\(path)\" 부근의 형식이 올바르지 않습니다.")
        @unknown default:
            return tr("Could not read the config.", "설정을 해석할 수 없습니다.")
        }
    }
}
