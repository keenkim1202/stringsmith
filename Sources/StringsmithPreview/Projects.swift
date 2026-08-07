import AppKit
import Foundation
import StringsmithCore

// MARK: - 프로젝트

/// 확인할 번역 소스 하나. `.stringsmith.json` 경로로 가리킨다.
struct PreviewProject: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// `.stringsmith.json` 절대 경로.
    var configPath: String
    /// 사용자가 붙인 이름. 없으면 경로에서 유추한다.
    var alias: String?

    init(id: UUID = UUID(), configPath: String, alias: String? = nil) {
        self.id = id
        self.configPath = configPath
        self.alias = alias
    }

    /// 탭에 보일 이름.
    ///
    /// 별칭이 없으면 설정 파일이 든 **폴더 이름**을 쓴다. 설정 파일명은 전부 같아서
    /// (`.stringsmith.json`) 구분이 안 되기 때문이다.
    var displayName: String {
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty { return alias }
        let directory = (configPath as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? configPath : name
    }
}

/// 프로젝트 목록. 앱을 껐다 켜도 유지된다.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [PreviewProject] = []
    @Published var selection: PreviewProject.ID?

    private let defaultsKey = "projects"

    init() {
        load()
        // CLI 가 넘겨준 경로가 있으면 추가하고 그 탭을 연다.
        for path in CommandLine.arguments.dropFirst() where path.hasSuffix(".json") {
            add(configPath: path)
        }
        if selection == nil { selection = projects.first?.id }
        observeOpenRequests()
    }

    /// 앱이 이미 떠 있을 때 `stringsmith preview` 가 보내는 요청을 받는다.
    private func observeOpenRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: .stringsmithOpenProject, object: nil, queue: .main
        ) { [weak self] notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                self?.add(configPath: path)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: 조회

    var selected: PreviewProject? {
        projects.first { $0.id == selection }
    }

    // MARK: 변경

    /// 같은 경로가 이미 있으면 새로 넣지 않고 그 탭을 고른다.
    @discardableResult
    func add(configPath: String) -> PreviewProject.ID {
        let resolved = Self.resolve(configPath)
        if let existing = projects.first(where: { $0.configPath == resolved }) {
            selection = existing.id
            return existing.id
        }
        let project = PreviewProject(configPath: resolved)
        projects.append(project)
        selection = project.id
        save()
        return project.id
    }

    func remove(_ id: PreviewProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects.remove(at: index)
        if selection == id {
            selection = projects.indices.contains(index) ? projects[index].id : projects.last?.id
        }
        save()
    }

    func rename(_ id: PreviewProject.ID, to alias: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        projects[index].alias = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func move(_ id: PreviewProject.ID, onto target: PreviewProject.ID) {
        guard id != target,
            let from = projects.firstIndex(where: { $0.id == id }),
            let to = projects.firstIndex(where: { $0.id == target })
        else { return }
        let moved = projects.remove(at: from)
        projects.insert(moved, at: to)
        save()
    }

    // MARK: 저장

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([PreviewProject].self, from: data)
        else { return }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// 상대 경로·디렉터리를 설정 파일 절대 경로로 정규화한다.
    static func resolve(_ path: String) -> String {
        var full =
            path.hasPrefix("/")
            ? path
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            full = (full as NSString).appendingPathComponent(Configuration.defaultFileName)
        }
        return (full as NSString).standardizingPath
    }
}

// MARK: - 읽어들인 번역

/// 한 프로젝트를 읽은 결과. 화면이 필요한 것만 담는다.
struct ProjectSnapshot: Sendable {
    struct Entry: Identifiable, Sendable {
        var key: String
        var screen: String?
        var comment: String?
        /// 원본 표기의 변수 이름. 입력 칸 라벨로 쓴다 (`arg1` 보다 `count` 가 낫다).
        var placeholders: [String]
        /// 변환 후 값 (`%1$@` 형태).
        var values: [String: String]
        /// 변환 전 값 (`{name}` 형태).
        var rawValues: [String: String]

        var id: String { key }
        var hasVariables: Bool { !placeholders.isEmpty }

        func isMissing(_ locale: String) -> Bool { (values[locale] ?? "").isEmpty }

        /// 그룹 머리글. 화면 컬럼이 있으면 그것을, 없으면 키의 앞머리를 쓴다.
        func group(fallback: String) -> String {
            if let screen, !screen.isEmpty { return screen }
            if let separator = key.first(where: { $0 == "_" || $0 == "." }) {
                let parts = key.split(separator: separator)
                if parts.count >= 2 { return String(parts[0]) }
            }
            return fallback
        }
    }

    var sourceLocale: String
    var locales: [String]
    var entries: [Entry]
    var warnings: [String]
    /// 시트 파일 경로. 갱신 시각과 함께 상단에 보여준다.
    var sheetPath: String
    var loadedAt: Date

    // MARK: 읽기

    /// 설정을 읽어 시트를 파싱하고 변수를 변환한다. CLI 의 `generate` 와 같은 경로를 쓴다.
    static func load(configPath: String) throws -> ProjectSnapshot {
        let configuration = try Configuration.load(from: configPath)
        let base = (configPath as NSString).deletingLastPathComponent
        let pipeline = Pipeline(
            configuration: configuration,
            baseDirectory: base.isEmpty ? FileManager.default.currentDirectoryPath : base
        )
        let raw = try pipeline.loadTable()
        let processed = PlaceholderProcessor(config: configuration.placeholders).process(raw)
        if !processed.errors.isEmpty {
            throw StringsmithError.validationFailed(issues: processed.errors.map(\.formatted))
        }

        let parser = PlaceholderParser(config: configuration.placeholders)
        var rawByKey: [String: LocalizationEntry] = [:]
        for entry in raw.entries { rawByKey[entry.key] = entry }

        let entries = processed.table.entries.map { entry -> Entry in
            var names: [String] = []
            if let source = rawByKey[entry.key]?.values[raw.sourceLocale] {
                for placeholder in parser.parse(source).0.placeholders {
                    let label = placeholder.name ?? "arg\(names.count + 1)"
                    if !names.contains(label) { names.append(label) }
                }
            }
            return Entry(
                key: entry.key,
                screen: entry.screen,
                comment: entry.comment,
                placeholders: names,
                values: entry.values,
                rawValues: rawByKey[entry.key]?.values ?? entry.values
            )
        }

        let sheet = configuration.source.path.hasPrefix("/")
            ? configuration.source.path
            : (base as NSString).appendingPathComponent(configuration.source.path)

        return ProjectSnapshot(
            sourceLocale: processed.table.sourceLocale,
            locales: processed.table.locales,
            entries: entries,
            warnings: processed.warnings.map(\.formatted),
            sheetPath: sheet,
            loadedAt: Date()
        )
    }
}
