import Foundation
import Testing

@testable import StringsmithCore

@Suite("드리프트 검출")
struct DriftTests {

    /// 파일 몇 개짜리 소스 트리를 만든다.
    func makeTree(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stringsmith-drift-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root.path
    }

    func accessors(_ pairs: [(String, String)]) -> [SwiftCodegen.Accessor] {
        pairs.enumerated().map { index, pair in
            SwiftCodegen.Accessor(key: pair.0, path: pair.1, location: "\(index + 2)")
        }
    }

    // MARK: 시트에만 있는 키

    @Test("코드에서 접근자를 쓰지 않는 키를 찾는다")
    func findsUnusedKeys() throws {
        let root = try makeTree([
            "Sources/View.swift": "let title = L10n.Home.title"
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(
            accessors: accessors([
                ("home.title", "L10n.Home.title"),
                ("home.subtitle", "L10n.Home.subtitle"),
            ]),
            root: root)

        #expect(report.unused.map(\.key) == ["home.subtitle"])
        // 지울 곳은 시트다. 그 자리를 짚어야 한다.
        #expect(report.unused.first?.location == "3")
    }

    /// 생성된 타입을 우회해 문자열로 부르는 것도 "쓰고 있다" 다.
    @Test("문자열로 부르는 키도 사용으로 센다")
    func countsStringCallsAsUse() throws {
        let root = try makeTree([
            "Sources/View.swift": """
                let a = NSLocalizedString("home.title", comment: "")
                let b = String(localized: "home.subtitle")
                let c = LocalizedStringKey("cart.empty")
                """
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(
            accessors: accessors([
                ("home.title", "L10n.Home.title"),
                ("home.subtitle", "L10n.Home.subtitle"),
                ("cart.empty", "L10n.Cart.empty"),
            ]),
            root: root)

        #expect(report.unused.isEmpty)
    }

    // MARK: 코드에만 있는 키

    @Test("시트에 없는 키를 파일과 줄 번호까지 짚는다")
    func findsUndefinedKeys() throws {
        let root = try makeTree([
            "Sources/View.swift": """
                import SwiftUI
                let a = NSLocalizedString("home.title", comment: "")
                let b = NSLocalizedString("profile.header", comment: "")
                """
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(
            accessors: accessors([("home.title", "L10n.Home.title")]), root: root)

        #expect(report.undefined.count == 1)
        #expect(report.undefined.first?.key == "profile.header")
        #expect(report.undefined.first?.line == 3)
        // 경로는 훑기 시작한 곳 기준이어야 클릭해서 열 수 있다.
        #expect(report.undefined.first?.file == "Sources/View.swift")
    }

    /// SwiftUI 의 `Text("...")` 는 리터럴이 곧 키라서, 넣으면 화면의 모든 문구가 후보가 된다.
    @Test("Text 리터럴은 키로 보지 않는다")
    func ignoresPlainTextLiterals() throws {
        let root = try makeTree([
            "Sources/View.swift": #"Text("this is not a key")"#
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(accessors: [], root: root)
        #expect(report.undefined.isEmpty)
    }

    // MARK: 훑는 범위

    /// 생성된 파일에는 모든 키가 정의되어 있다. 세면 전부 "쓰고 있다" 가 된다.
    @Test("지정한 파일은 훑지 않는다")
    func honoursTheIgnoreList() throws {
        let root = try makeTree([
            "Resources/L10n.swift": "enum L10n { static var homeTitle: String { \"\" } }\nL10n.Home.title",
            "Sources/View.swift": "// 아무것도 쓰지 않는다",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let generated = root + "/Resources/L10n.swift"
        let report = try DriftDetector().detect(
            accessors: accessors([("home.title", "L10n.Home.title")]),
            root: root, ignoring: [generated])

        #expect(report.unused.map(\.key) == ["home.title"])
        #expect(report.filesScanned == 1)
    }

    @Test("빌드 산출물과 의존성은 건너뛴다")
    func skipsBuildDirectories() throws {
        let root = try makeTree([
            ".build/Generated.swift": #"NSLocalizedString("ignored.one", comment: "")"#,
            "Pods/Thing.swift": #"NSLocalizedString("ignored.two", comment: "")"#,
            "DerivedData/X.swift": #"NSLocalizedString("ignored.three", comment: "")"#,
            "Sources/View.swift": #"NSLocalizedString("real.key", comment: "")"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(accessors: [], root: root)

        #expect(report.filesScanned == 1)
        #expect(report.undefined.map(\.key) == ["real.key"])
    }

    @Test("Swift 가 아닌 파일은 보지 않는다")
    func onlyReadsSwift() throws {
        let root = try makeTree([
            "README.md": #"NSLocalizedString("not.code", comment: "")"#,
            "Sources/View.swift": "// 비어 있음",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(accessors: [], root: root)
        #expect(report.filesScanned == 1)
        #expect(report.undefined.isEmpty)
    }

    // MARK: 그 밖에

    @Test("어긋난 게 없으면 깨끗하다고 한다")
    func reportsClean() throws {
        let root = try makeTree(["Sources/View.swift": "let t = L10n.Home.title"])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = try DriftDetector().detect(
            accessors: accessors([("home.title", "L10n.Home.title")]), root: root)
        #expect(report.isClean)
    }

    @Test("없는 디렉터리는 그렇다고 말한다")
    func explainsAMissingDirectory() {
        #expect(throws: StringsmithError.self) {
            try DriftDetector().detect(accessors: [], root: "/nope/not/here")
        }
    }
}
