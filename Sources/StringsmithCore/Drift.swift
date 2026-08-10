import Foundation

/// 시트와 코드가 어긋난 곳.
///
/// 생성된 접근자만 쓴다면 "코드에 있는데 시트에 없는 키" 는 컴파일이 막아 준다. 실제로
/// 새어 나가는 건 두 가지다 — 아무도 안 쓰는데 계속 번역료를 물고 있는 키, 그리고 생성된
/// 타입을 우회해 문자열로 직접 부르는 자리. 둘 다 조용히 쌓인다.
public struct DriftReport: Sendable, Equatable {
    /// 시트에 있는데 코드 어디에서도 쓰지 않는 키.
    public var unused: [Unused]
    /// 코드가 문자열로 부르는데 시트에 없는 키.
    public var undefined: [Undefined]
    /// 훑어본 Swift 파일 수.
    public var filesScanned: Int

    public var isClean: Bool { unused.isEmpty && undefined.isEmpty }

    public struct Unused: Sendable, Equatable {
        public var key: String
        /// 시트에서의 자리. 지울 곳이다.
        public var location: String
        /// 찾아봤던 접근자 경로.
        public var accessor: String
    }

    public struct Undefined: Sendable, Equatable {
        public var key: String
        /// 파일 경로(기준 디렉터리 상대).
        public var file: String
        public var line: Int
    }
}

public struct DriftDetector: Sendable {

    /// 훑지 않을 디렉터리.
    ///
    /// 빌드 산출물과 의존성까지 뒤지면 느리기만 하고, 거기서 나온 키는 이 프로젝트의 것이 아니다.
    public static let skippedDirectories: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage", "node_modules", ".swiftpm",
    ]

    /// 문자열로 로컬라이제이션을 부르는 자리.
    ///
    /// SwiftUI 의 `Text("...")` 는 일부러 넣지 않았다. 리터럴이 곧 키라서 화면의 모든 문구가
    /// 후보가 되고, 시트에 없다고 전부 보고하면 목록이 쓸모없어진다.
    static let callPatterns = [
        #"NSLocalizedString\(\s*"([^"]+)""#,
        #"String\(\s*localized:\s*"([^"]+)""#,
        #"LocalizedStringKey\(\s*"([^"]+)""#,
    ]

    public init() {}

    /// `root` 아래의 Swift 코드를 훑어 시트와 대조한다.
    ///
    /// - Parameters:
    ///   - accessors: 시트에서 만들어진 접근자들.
    ///   - root: 훑을 디렉터리.
    ///   - ignoring: 건너뛸 파일 경로. 생성된 파일 자신이 여기 온다 — 거기엔 모든 키가
    ///     정의되어 있으므로 세면 전부 "쓰고 있다" 가 된다.
    public func detect(
        accessors: [SwiftCodegen.Accessor],
        root: String,
        ignoring: Set<String> = []
    ) throws -> DriftReport {
        // 경로를 먼저 같은 형태로 만든다. macOS 는 /var 를 /private/var 로 이어 두어서,
        // 문자열 그대로 비교하면 같은 파일이 다른 경로로 보인다. 그러면 생성된 파일이
        // 제외되지 않고, 거기 정의된 모든 키가 "쓰고 있다" 로 세어져 아무것도 보고하지 않는다.
        let root = Self.canonical(root)
        let ignoring = Set(ignoring.map(Self.canonical))
        let files = try swiftFiles(under: root, ignoring: ignoring)

        var usedKeys = Set<String>()
        var undefined: [DriftReport.Undefined] = []
        let known = Set(accessors.map(\.key))
        let expressions = Self.callPatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }

        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let relative = Self.relative(file, to: root)

            // 생성된 접근자를 쓰고 있는가.
            for accessor in accessors where text.contains(accessor.path) {
                usedKeys.insert(accessor.key)
            }

            // 문자열로 직접 부르는 자리.
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for expression in expressions {
                    for match in expression.matches(in: text, range: range) {
                        guard match.numberOfRanges > 1,
                            let captured = Range(match.range(at: 1), in: text)
                        else { continue }
                        let key = String(text[captured])
                        if known.contains(key) {
                            usedKeys.insert(key)
                        } else {
                            undefined.append(
                                DriftReport.Undefined(
                                    key: key, file: relative, line: number + 1))
                        }
                    }
                }
            }
        }

        let unused =
            accessors
            .filter { !usedKeys.contains($0.key) }
            .map {
                DriftReport.Unused(key: $0.key, location: $0.location, accessor: $0.path)
            }

        return DriftReport(
            unused: unused, undefined: undefined, filesScanned: files.count)
    }

    // MARK: 경로

    /// 심볼릭 링크를 풀고 `.`·`..` 를 정리한다.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 훑기 시작한 곳 기준의 경로. 터미널에서 클릭해 열 수 있어야 한다.
    static func relative(_ path: String, to root: String) -> String {
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    // MARK: 파일 훑기

    func swiftFiles(under root: String, ignoring: Set<String>) throws -> [String] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw StringsmithError.io(
                path: root,
                reason: tr("No such directory.", "그런 디렉터리가 없습니다."))
        }
        guard isDirectory.boolValue else {
            throw StringsmithError.io(
                path: root,
                reason: tr("Not a directory.", "디렉터리가 아닙니다."))
        }

        guard
            let walker = manager.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var found: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if Self.skippedDirectories.contains(name) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let path = Self.canonical(url.path)
            if ignoring.contains(path) { continue }
            found.append(path)
        }
        return found.sorted()
    }
}
