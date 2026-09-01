import ArgumentParser
import Foundation
import StringsmithCore

extension Stringsmith {

    /// 시트와 코드가 어긋난 곳을 찾는다.
    ///
    /// 생성된 접근자만 쓴다면 "코드에 있는데 시트에 없는 키" 는 컴파일이 막아 준다. 남는 건
    /// 아무도 안 쓰는데 계속 번역료를 물고 있는 키와, 생성된 타입을 우회해 문자열로 부르는
    /// 자리다. 둘 다 조용히 쌓여서 누가 찾아보기 전에는 드러나지 않는다.
    struct Drift: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drift",
            abstract: .init(
                stringLiteral: tr(
                    "Find keys the sheet and the code disagree on.",
                    "시트와 코드가 어긋난 키를 찾습니다.")))

        @Argument(
            help: .init(
                stringLiteral: tr(
                    "Directory to scan. Defaults to the config's directory.",
                    "훑을 디렉터리. 생략하면 설정 파일이 있는 곳.")))
        var path: String?

        @Option(
            name: [.short, .long],
            help: .init(stringLiteral: tr("Path to .stringsmith.json.", "설정 파일 경로.")))
        var config: String?

        @Flag(
            name: [.short, .long],
            help: .init(stringLiteral: tr("List every finding.", "찾은 것을 모두 나열합니다.")))
        var verbose = false

        @Flag(
            name: [.long],
            help: .init(
                stringLiteral: tr(
                    "Exit non-zero if anything drifted.", "어긋난 게 있으면 실패로 처리합니다.")))
        var strict = false

        func run() throws {
            Stringsmith.configureBuffering()
            let config = try Stringsmith.resolveConfigPath(self.config)
            let configuration = try Configuration.load(from: config)
            let base = (config as NSString).deletingLastPathComponent

            let pipeline = Pipeline(configuration: configuration, baseDirectory: base)
            let report = try pipeline.drift(root: path ?? base)

            print(
                "🔍 " + tr(
                    "Scanned \(report.filesScanned) Swift file(s).",
                    "Swift 파일 \(report.filesScanned)개를 훑었습니다."))

            if report.isClean {
                print("\n✅ " + tr("Sheet and code agree.", "시트와 코드가 일치합니다."))
                return
            }

            // 시트에만 있는 키. 지우면 번역 비용이 준다.
            if !report.unused.isEmpty {
                print(
                    "\n📄→ " + tr(
                        "\(report.unused.count) key(s) in the sheet, never used in code:",
                        "시트에만 있고 코드에서 쓰지 않는 키 \(report.unused.count)개:"))
                for item in trimmed(report.unused) {
                    print(
                        "     \(item.key) "
                            + Terminal.dim(
                                tr("(row \(item.location)) — \(item.accessor)",
                                   "(행 \(item.location)) — \(item.accessor)")))
                }
                printRest(report.unused.count)
            }

            // 코드에만 있는 키. 런타임에 조용히 원문으로 대체되므로 컴파일로는 못 잡는다.
            if !report.undefined.isEmpty {
                print(
                    "\n→📄 " + tr(
                        "\(report.undefined.count) key(s) used in code but missing from the sheet:",
                        "코드에서 쓰는데 시트에 없는 키 \(report.undefined.count)개:"))
                for item in trimmed(report.undefined) {
                    print(
                        "     \(item.key) "
                            + Terminal.dim("\(item.file):\(item.line)"))
                }
                printRest(report.undefined.count)
            }

            guard strict else {
                print(
                    "\n" + Terminal.dim(
                        tr(
                            "Nothing was changed. Use --strict to fail on drift.",
                            "아무것도 바꾸지 않았습니다. --strict 로 실패 처리할 수 있습니다.")))
                return
            }
            // 3 = 시트 내용이 검증을 통과하지 못함. 설정 오류(2)와 구분한다.
            throw ExitCode(3)
        }

        // MARK: 출력 다듬기

        static let limit = 10

        func trimmed<T>(_ items: [T]) -> [T] {
            verbose ? items : Array(items.prefix(Self.limit))
        }

        func printRest(_ total: Int) {
            guard !verbose, total > Self.limit else { return }
            print(
                "     "
                    + Terminal.dim(
                        tr(
                            "… \(total - Self.limit) more (-v shows all)",
                            "… 외 \(total - Self.limit)건 (-v 로 전부 봅니다)")))
        }
    }
}
