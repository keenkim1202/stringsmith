import SwiftUI

/// 시트 한 장에서 화면까지 이어지는 예제.
///
/// 눈여겨볼 곳은 `ContentView` 다 — 문자열 리터럴도, 키 이름도 나오지 않는다.
/// `strings.csv` 를 고치고 `stringsmith generate` 를 돌리면 그대로 반영된다.
@main
struct DemoApp: App {

    init() {
        // 창을 띄우지 않고 문자열만 찍는 길. 사람이 눈으로 보기에도, CI 가 "키가 그대로
        // 나오지 않는지" 확인하기에도 이쪽이 낫다.
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup(L10n.App.title) {
            ContentView()
                .frame(minWidth: 380, minHeight: 320)
        }
    }
}

/// `--dump` 가 하는 일.
enum Dump {

    static func run() {
        let arguments = CommandLine.arguments

        // `--lang ko` 를 주면 그 언어로만 찍는다.
        if let flag = arguments.firstIndex(of: "--lang"), flag + 1 < arguments.count {
            show(arguments[flag + 1])
            return
        }

        // 기본은 앱이 실제로 고른 언어.
        print("● \(Bundle.module.preferredLocalizations.first ?? "?") (system)")
        print(L10n.App.title)
        print(L10n.App.subtitle)
        print(L10n.Cart.greeting("김소연"))
        print(L10n.Cart.items(1))
        print(L10n.Cart.items(3))
        print(L10n.Cart.discount("김소연"))
    }

    /// 한 언어의 `.lproj` 를 직접 열어 찍는다.
    ///
    /// QA 화면이 하는 일과 같다 — 기기 언어를 바꾸지 않고 다른 언어를 확인한다.
    /// `L10n` 을 거치지 않는 건 생성 코드가 번들을 고정으로 들고 있기 때문이다.
    /// 앱에서 이렇게 쓸 일은 드물고, 보통은 Xcode 스킴의 App Language 로 바꾼다.
    static func show(_ language: String) {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            let known = Bundle.module.localizations.sorted().joined(separator: ", ")
            print("no such language: \(language) — have: \(known)")
            return
        }

        func string(_ key: String, _ arguments: CVarArg...) -> String {
            let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
            guard !arguments.isEmpty else { return format }
            return String(format: format, locale: Locale(identifier: language), arguments: arguments)
        }

        print("● \(language)")
        print(string("app.title"))
        print(string("app.subtitle"))
        print(string("cart.greeting", "김소연"))
        // 복수형은 stringsdict 에 있어 같은 키로 찾되 수에 따라 형태가 바뀐다.
        print(string("cart.items", 1))
        print(string("cart.items", 3))
        print(string("cart.discount", "김소연"))
    }
}
