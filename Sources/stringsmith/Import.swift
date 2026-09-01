import ArgumentParser
import Foundation
import StringsmithCore

extension Stringsmith {

    /// 이미 있는 로컬라이제이션 파일에서 시트를 만든다.
    ///
    /// 나머지 명령이 전부 "시트가 이미 있다" 를 전제하므로, 기존 프로젝트에는 이게 첫 문이다.
    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: .init(stringLiteral: tr(
                "Draft a sheet from localization files you already have.",
                "이미 있는 로컬라이제이션 파일에서 시트 초안을 만듭니다.")),
            discussion: tr(
                """
                Point at a .xcstrings file, or at the directory holding your .lproj folders.
                Plurals become key suffixes (cart.items.one), which is how the sheet writes them.

                Variables arrive as {arg1}, {arg2}. The files only record where a variable sits,
                never what it held, so rename them in the sheet before you generate.
                """,
                """
                .xcstrings 파일이나 .lproj 들이 있는 디렉터리를 가리키면 됩니다.
                복수형은 키 접미사(cart.items.one)가 됩니다. 시트가 복수형을 적는 방식입니다.

                변수는 {arg1}, {arg2} 로 들어갑니다. 파일에는 변수의 자리만 있고 그게 무엇이었는지는
                남아 있지 않습니다. generate 전에 시트에서 이름을 고치세요.
                """))

        @Argument(help: .init(stringLiteral: tr(
            "A .xcstrings file, or a directory of .lproj folders.",
            ".xcstrings 파일 또는 .lproj 들이 있는 디렉터리.")))
        var path: String

        @Option(name: [.short, .long], help: .init(stringLiteral: tr(
            "Where to write the sheet.", "시트를 쓸 경로.")))
        var output = "strings.csv"

        @Option(name: [.long], help: .init(stringLiteral: tr(
            "Source locale. .lproj folders do not record it; a String Catalog does.",
            "원문 로케일. .lproj 는 이 정보를 담지 않습니다. String Catalog 은 담고 있습니다.")))
        var source: String?

        @Flag(name: [.short, .long], help: .init(stringLiteral: tr(
            "List every key, not the first few.", "일부가 아니라 전부 보여줍니다.")))
        var verbose = false

        @Flag(name: [.long], help: .init(stringLiteral: tr(
            "Overwrite the output file.", "출력 파일을 덮어씁니다.")))
        var force = false

        func run() throws {
            Stringsmith.configureBuffering()

            // 덮어쓰기는 물어보고 한다. 손으로 이름을 고쳐 둔 시트를 날리면 그 작업이 통째로 사라진다.
            if FileManager.default.fileExists(atPath: output), !force {
                throw CLIError(tr(
                    """
                    \(output) already exists.
                      → Pass --force to overwrite it, or -o to write somewhere else.
                    """,
                    """
                    \(output) 이(가) 이미 있습니다.
                      → --force 로 덮어쓰거나, -o 로 다른 경로에 쓰세요.
                    """))
            }

            let result = try LocalizationImport.read(path: path, sourceLocale: source)
            guard result.keyCount > 0 else {
                throw CLIError(tr(
                    "Found no translations in \(path).",
                    "\(path) 에서 번역을 찾지 못했습니다."))
            }

            let text = CSVParser.serialize(result.rows) + "\n"
            do {
                try Data(text.utf8).write(to: URL(fileURLWithPath: output))
            } catch {
                throw StringsmithError.io(path: output, reason: error.localizedDescription)
            }

            print("📄 " + tr(
                "\(result.keyCount) keys · \(result.locales.count) languages "
                    + "(\(result.locales.joined(separator: ", ")))",
                "키 \(result.keyCount)개 · 언어 \(result.locales.count)개 "
                    + "(\(result.locales.joined(separator: ", ")))"))
            print("✍️  " + output)

            report(
                result.needsNaming,
                title: tr(
                    "\(result.needsNaming.count) key(s) have variables named {arg1}:",
                    "변수가 {arg1} 로 들어간 키 \(result.needsNaming.count)개:"),
                hint: tr(
                    "     → Rename them in the sheet. A wrong name compiles and reads wrong.",
                    "     → 시트에서 이름을 고치세요. 틀린 이름도 컴파일은 됩니다."))

            report(
                result.skipped,
                title: tr(
                    "\(result.skipped.count) thing(s) did not come across:",
                    "옮기지 못한 것 \(result.skipped.count)개:"),
                hint: nil)

            print("\n→ " + tr(
                "Next: `stringsmith init \(output)` writes the config.",
                "다음: `stringsmith init \(output)` 로 설정을 만듭니다."))
        }

        /// 경고 한 덩어리. 기본은 앞의 몇 개만 보여준다 — 300줄이 흐르면 아무도 읽지 않는다.
        func report(_ items: [String], title: String, hint: String?) {
            guard !items.isEmpty else { return }
            print("\n⚠️ " + title)
            let limit = 10
            for item in verbose ? items : Array(items.prefix(limit)) {
                print("     " + item)
            }
            if !verbose, items.count > limit {
                print("     " + Terminal.dim(tr(
                    "… \(items.count - limit) more (-v shows all)",
                    "… 외 \(items.count - limit)건 (-v 로 전부 봅니다)")))
            }
            if let hint { print(Terminal.dim(hint)) }
        }
    }
}
