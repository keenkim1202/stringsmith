import ArgumentParser
import Foundation
import StringsmithCore

extension Stringsmith {

    /// 시트만 보고 검증한다. 파일은 만들지 않는다.
    ///
    /// `generate` 와 나눠 둔 건 쓰는 사람이 다르기 때문이다. 기획자·번역가는 시트를 고친 뒤
    /// "이대로 개발자에게 넘겨도 되나" 만 알면 되고, 그 답을 받자고 남의 작업 디렉터리에
    /// 파일을 만들 이유가 없다.
    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: .init(
                stringLiteral: tr(
                    "Check the sheet without writing anything.",
                    "파일을 만들지 않고 시트만 검사합니다.")),
            aliases: ["check"])

        @Option(
            name: [.short, .long],
            help: .init(
                stringLiteral: tr(
                    "Path to .stringsmith.json.", "설정 파일 경로.")))
        var config: String?

        @Flag(
            name: [.short, .long],
            help: .init(
                stringLiteral: tr(
                    "Show every variable conversion.", "변수 변환을 모두 보여줍니다.")))
        var verbose = false

        @Flag(
            name: [.long],
            help: .init(
                stringLiteral: tr(
                    "Exit non-zero if there are warnings, not just errors.",
                    "경고만 있어도 실패로 처리합니다.")))
        var strict = false

        func run() throws {
            Stringsmith.configureBuffering()
            let config = try Stringsmith.resolveConfigPath(self.config)
            let configuration = try Configuration.load(from: config)
            let base = (config as NSString).deletingLastPathComponent

            let pipeline = Pipeline(configuration: configuration, baseDirectory: base)
            let result = try pipeline.validate()
            let table = result.table

            print(
                "📄 " + tr(
                    "\(table.entries.count) keys · \(table.locales.count) languages "
                        + "(\(table.locales.joined(separator: ", ")))",
                    "키 \(table.entries.count)개 · 언어 \(table.locales.count)개 "
                        + "(\(table.locales.joined(separator: ", ")))"))

            WarningOutput.print(result.warnings, verbose: verbose)

            // 변환은 기본으로 건수만 알린다. 검증이 목적이라 목록까지 볼 일은 드물다.
            if !result.conversions.isEmpty {
                if verbose {
                    print(
                        "\n🔤 " + tr(
                            "\(result.conversions.count) variable conversions:",
                            "변수 변환 \(result.conversions.count)건:"))
                    for conversion in result.conversions {
                        print("  " + Terminal.dim("\(conversion.key) [\(conversion.locale)]"))
                        print("    " + Terminal.removed("- \(conversion.before)"))
                        print("    " + Terminal.added("+ \(conversion.after)"))
                    }
                } else {
                    print(
                        "🔤 " + tr(
                            "\(result.conversions.count) variable conversions (-v shows them)",
                            "변수 변환 \(result.conversions.count)건 (-v 로 봅니다)"))
                }
            }

            if result.warnings.isEmpty {
                print("\n✅ " + tr("No problems found.", "문제를 찾지 못했습니다."))
                return
            }

            let summary = tr(
                "\(result.warnings.count) warning(s).", "경고 \(result.warnings.count)건.")

            // 어떤 경고가 생성을 막는지는 설정이 정한다. 기본은 이름 충돌만이다 —
            // 아직 채우는 중인 시트에서 번역 누락은 당연한 상태이기 때문이다.
            let blocking = strict ? result.warnings : result.blocking
            guard blocking.isEmpty else {
                print(
                    "\n❌ " + summary + " "
                        + tr(
                            "\(blocking.count) of them stop `generate`.",
                            "그중 \(blocking.count)건이 generate 를 막습니다.")
                        + (strict ? tr(" (--strict)", " (--strict)") : ""))
                for warning in blocking {
                    print("     " + tr("blocking:", "차단:") + " \(warning.summary)")
                }
                if !strict {
                    print(
                        Terminal.dim(
                            tr(
                                "     → Change validation.failOn in the config to allow them.",
                                "     → 설정의 validation.failOn 을 고치면 통과시킬 수 있습니다.")))
                }
                // 3 = 시트 내용이 검증을 통과하지 못함. 설정 오류(2)와 구분한다.
                throw ExitCode(3)
            }
            print("\n⚠️ " + summary + " " + tr("Nothing blocking.", "생성을 막지는 않습니다."))
        }
    }
}
