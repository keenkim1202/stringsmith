import Foundation
import StringsmithCore

/// 경고를 사람이 읽을 수 있게 찍는다.
///
/// 요약만 찍으면 "번역 3건 누락" 에서 멈춘다 — 어디를 고쳐야 할지 모른 채로. 그래서 항목을
/// 함께 내되, 100건짜리 목록이 화면을 덮지 않도록 기본은 잘라서 낸다.
enum WarningOutput {

    /// 기본으로 보여 줄 항목 수. 이보다 많으면 몇 건 더 있는지만 알린다.
    static let defaultLimit = 5

    static func print(_ warnings: [Warning], verbose: Bool) {
        for warning in warnings {
            Swift.print("  ⚠️ \(warning.summary)")
            guard !warning.items.isEmpty else { continue }

            let shown = verbose ? warning.items : Array(warning.items.prefix(defaultLimit))
            for item in shown {
                Swift.print("       " + Terminal.dim(item.formatted))
            }
            let rest = warning.items.count - shown.count
            if rest > 0 {
                Swift.print(
                    "       "
                        + Terminal.dim(
                            tr(
                                "… \(rest) more (-v shows all)",
                                "… 외 \(rest)건 (-v 로 전부 봅니다)")))
            }
        }
    }
}
