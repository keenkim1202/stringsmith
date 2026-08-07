import Darwin
import Foundation

/// 터미널 색 출력.
///
/// 파이프나 파일로 내보낼 때는 색을 끈다. 그렇지 않으면 `ss generate > log.txt` 나
/// `ss generate | grep` 결과에 이스케이프 코드가 섞여 읽기 어렵고 비교도 깨진다.
enum Terminal {

    /// 색을 쓸지. 프로세스당 한 번만 판단한다.
    ///
    /// - `NO_COLOR` 가 있으면 끈다 (https://no-color.org 관례).
    /// - `FORCE_COLOR`·`CLICOLOR_FORCE` 가 있으면 파이프여도 켠다 (CI 로그 착색용).
    /// - `TERM=dumb` 는 이스케이프를 해석하지 못한다.
    /// - 그 외에는 표준 출력이 터미널일 때만 켠다.
    static let isColorEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil { return false }
        if env["FORCE_COLOR"] != nil || env["CLICOLOR_FORCE"] != nil { return true }
        if env["TERM"] == "dumb" { return false }
        return isatty(STDOUT_FILENO) == 1
    }()

    struct Color {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
    }

    /// GitHub 의 diff 배색을 참고했다. 어두운 배경에서 읽히도록 배경은 옅게 깔고
    /// 글자만 또렷한 색을 쓴다.
    enum Palette {
        static let removedText = Color(red: 248, green: 81, blue: 73)
        static let removedBackground = Color(red: 67, green: 26, blue: 26)
        static let addedText = Color(red: 63, green: 185, blue: 80)
        static let addedBackground = Color(red: 18, green: 45, blue: 32)
    }

    /// 24비트 색으로 칠한다. 색이 꺼져 있으면 원문 그대로 돌려준다.
    ///
    /// 배경은 **글자 뒤에만** 깔고 줄 끝까지 늘이지 않는다. 터미널 너비에 맞춰 채우면
    /// 긴 문구가 줄바꿈될 때 블록이 어긋나 보인다.
    static func paint(_ text: String, _ foreground: Color, on background: Color? = nil) -> String {
        guard isColorEnabled else { return text }
        var out = "\u{1B}[38;2;\(foreground.red);\(foreground.green);\(foreground.blue)m"
        if let background {
            out += "\u{1B}[48;2;\(background.red);\(background.green);\(background.blue)m"
        }
        return out + text + "\u{1B}[0m"
    }

    static func removed(_ text: String) -> String {
        paint(text, Palette.removedText, on: Palette.removedBackground)
    }

    static func added(_ text: String) -> String {
        paint(text, Palette.addedText, on: Palette.addedBackground)
    }

    static func dim(_ text: String) -> String {
        guard isColorEnabled else { return text }
        return "\u{1B}[2m" + text + "\u{1B}[0m"
    }
}
