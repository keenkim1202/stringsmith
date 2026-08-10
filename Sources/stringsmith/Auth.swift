import ArgumentParser
import Foundation
import StringsmithCore

extension Stringsmith {

    struct Auth: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auth",
            abstract: .init(
                stringLiteral: tr(
                    "Sign in to Google to read private sheets.",
                    "비공개 시트를 읽기 위해 Google 에 로그인합니다.")),
            subcommands: [Login.self, Logout.self, Status.self],
            defaultSubcommand: Status.self)

        // MARK: login

        struct Login: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: .init(
                    stringLiteral: tr(
                        "Sign in with a Google account.", "Google 계정으로 로그인합니다.")))

            func run() throws {
                Stringsmith.configureBuffering()
                let store = FileTokenStore()
                let oauth = GoogleOAuth()

                try oauth.login(
                    store: store,
                    openURL: { url in
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        process.arguments = [url.absoluteString]
                        try process.run()
                    },
                    announce: { print($0) })

                print(
                    tr(
                        "✅ Signed in. Tokens are stored in \(store.path) (mode 600).",
                        "✅ 로그인되었습니다. 토큰은 \(store.path) 에 저장됩니다 (권한 600)."))
                print(
                    Terminal.dim(
                        tr(
                            "   Private sheets now read through the Sheets API.",
                            "   이제 비공개 시트도 Sheets API 로 읽습니다.")))
            }
        }

        // MARK: logout

        struct Logout: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: .init(
                    stringLiteral: tr(
                        "Remove the stored sign-in.", "저장된 로그인을 삭제합니다.")))

            func run() throws {
                Stringsmith.configureBuffering()
                let store = FileTokenStore()
                let hadTokens = (try? store.load()) != nil
                try store.clear()

                print(
                    hadTokens
                        ? tr("✅ Signed out — \(store.path) removed.", "✅ 로그아웃했습니다 — \(store.path) 삭제됨.")
                        : tr("Not signed in; nothing to remove.", "로그인되어 있지 않아 삭제할 것이 없습니다."))
                // 토큰 파일을 지워도 구글 쪽 승인은 남는다. 완전히 끊으려면 계정 설정에서 해제해야 한다.
                print(
                    Terminal.dim(
                        tr(
                            "   To revoke access on Google's side: https://myaccount.google.com/permissions",
                            "   Google 쪽 접근 권한까지 해제하려면: https://myaccount.google.com/permissions")))
            }
        }

        // MARK: status

        struct Status: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: .init(
                    stringLiteral: tr(
                        "Show whether you are signed in.", "로그인 상태를 보여줍니다.")))

            func run() throws {
                Stringsmith.configureBuffering()

                guard GoogleClient.isConfigured else {
                    print(GoogleClient.notConfiguredMessage)
                    return
                }
                guard let tokens = try FileTokenStore().load() else {
                    print(tr("Not signed in.", "로그인되어 있지 않습니다."))
                    print(Terminal.dim(tr("  → Run: ss auth login", "  → 실행: ss auth login")))
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let expiry = formatter.string(from: tokens.expiresAt)

                if tokens.isExpired() {
                    print(
                        tr(
                            "Signed in. The access token expired at \(expiry); it renews on the next run.",
                            "로그인되어 있습니다. 액세스 토큰은 \(expiry) 에 만료됐고 다음 실행 때 갱신됩니다."))
                } else {
                    print(
                        tr(
                            "Signed in. The access token is valid until \(expiry).",
                            "로그인되어 있습니다. 액세스 토큰은 \(expiry) 까지 유효합니다."))
                }
                print(Terminal.dim("  \(FileTokenStore.defaultPath)"))
            }
        }
    }
}
