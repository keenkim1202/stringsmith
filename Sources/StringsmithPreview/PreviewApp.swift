import AppKit
import SwiftUI

/// 앱 UI 문구를 시스템 언어로 가져온다.
///
/// `.lproj` 선택은 macOS 가 사용자 언어 설정을 보고 하며, 지원하지 않는 언어면
/// `defaultLocalization`(en) 으로 떨어진다.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// 창을 다른 앱 위로 올리거나 내린다.
///
/// `.floating` 은 앱이 비활성이어도 위에 남는다. SwiftUI 에 대응하는 수식어가 없어
/// AppKit 창을 직접 찾아 설정한다.
@MainActor
func applyWindowLevel(_ onTop: Bool) {
    for window in NSApplication.shared.windows {
        window.level = onTop ? .floating : .normal
    }
}

/// `.app` 번들 없이 `swift run` 으로 띄우면 macOS 가 **액세서리 프로세스**로 취급해
/// 창은 보이지만 키보드 입력을 받지 못한다. 실행 시점에 정책을 올려 정상 앱으로 만든다.
/// (`make app` 으로 만든 번들에서는 이미 정상이지만 두어도 해가 없다.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let onTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        Task { @MainActor in applyWindowLevel(onTop) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ProjectStore()
    /// 기본은 꺼짐. 켜면 다음 실행에도 유지된다.
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some Scene {
        WindowGroup(L("window.title")) {
            ContentView(store: store)
                .frame(minWidth: 780, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("project.add")) { store.addWithPicker() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L("action.refresh")) {
                    NotificationCenter.default.post(name: .stringsmithRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // 새 메뉴를 만들면 SwiftUI 기본 "View" 메뉴와 이름이 겹친다.
            // 창을 앞에 고정하는 항목은 macOS 관례상 Window 메뉴에 있으므로 거기 넣는다.
            CommandGroup(after: .windowArrangement) {
                Toggle(
                    L("menu.alwaysOnTop"),
                    isOn: Binding(
                        get: { alwaysOnTop },
                        set: { alwaysOnTop = $0; applyWindowLevel($0) }
                    )
                )
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    /// ⌘R 이 선택된 탭을 다시 읽게 한다.
    static let stringsmithRefresh = Notification.Name("stringsmith.refresh")
    /// `stringsmith preview` 가 이미 떠 있는 앱에 프로젝트를 넘길 때 쓴다.
    static let stringsmithOpenProject = Notification.Name("stringsmith.openProject")
}

extension ProjectStore {
    /// 파일 선택 창으로 프로젝트를 추가한다.
    ///
    /// `.stringsmith.json` 은 점으로 시작해 기본 상태에서는 보이지 않으므로 숨김 파일을 켜 둔다.
    /// 폴더를 골라도 되도록 디렉터리 선택도 허용한다.
    func addWithPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.message = L("project.pickMessage")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(configPath: url.path)
        }
    }
}
