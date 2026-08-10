import Foundation
import Testing

@testable import StringsmithCore

/// 실제 소켓을 열고 진짜 HTTP 요청을 보낸다.
///
/// 이 부분은 raw POSIX 소켓이라 가짜로 대체하면 검증되는 게 없다. 브라우저가 보내는 것과
/// 같은 모양의 요청을 실제로 던져 본다.
@Suite("loopback 서버", .serialized)
struct LoopbackServerTests {

    /// 서버가 코드를 받을 때까지 기다리는 동안 별도 스레드에서 요청을 보낸다.
    func request(_ path: String, to port: UInt16) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    @Test("커널이 고른 포트로 열린다")
    func bindsToAnEphemeralPort() throws {
        let server = try LoopbackServer()
        #expect(server.port > 0)
        #expect(server.redirectURI == "http://127.0.0.1:\(server.port)")
    }

    @Test("포트를 고정하지 않아 동시에 여러 개가 열린다")
    func allowsConcurrentLogins() throws {
        let first = try LoopbackServer()
        let second = try LoopbackServer()
        // 고정 포트였다면 두 번째가 실패한다 — 로그인 중에 다른 로그인이 막히면 안 된다.
        #expect(first.port != second.port)
    }

    @Test("브라우저가 돌려준 코드를 꺼낸다")
    func extractsTheAuthorizationCode() throws {
        let server = try LoopbackServer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.request("/?code=THE_CODE&state=STATE", to: server.port)
        }

        let code = try server.waitForCode(
            state: "STATE", deadline: Date().addingTimeInterval(5))
        #expect(code == "THE_CODE")
    }

    /// 브라우저는 요청한 적 없는 /favicon.ico 를 함께 보낸다. 여기서 포기하면 로그인이 깨진다.
    @Test("관계없는 요청은 넘기고 계속 기다린다")
    func ignoresUnrelatedRequests() throws {
        let server = try LoopbackServer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.request("/favicon.ico", to: server.port)
            self.request("/?code=REAL&state=STATE", to: server.port)
        }

        let code = try server.waitForCode(
            state: "STATE", deadline: Date().addingTimeInterval(5))
        #expect(code == "REAL")
    }

    /// state 가 다르면 우리가 시작하지 않은 요청이다. 코드를 그대로 쓰면 안 된다.
    @Test("state 가 맞지 않으면 거부한다")
    func rejectsAMismatchedState() throws {
        let server = try LoopbackServer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.request("/?code=CODE&state=ATTACKER", to: server.port)
        }

        #expect(throws: StringsmithError.self) {
            try server.waitForCode(state: "MINE", deadline: Date().addingTimeInterval(5))
        }
    }

    @Test("사용자가 동의를 거부하면 그 사실을 알린다")
    func reportsADeclinedConsent() throws {
        let server = try LoopbackServer()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.request("/?error=access_denied&state=STATE", to: server.port)
        }

        #expect(throws: StringsmithError.self) {
            try server.waitForCode(state: "STATE", deadline: Date().addingTimeInterval(5))
        }
    }

    @Test("아무도 오지 않으면 기다리다 그만둔다")
    func givesUpWhenNobodyArrives() throws {
        let server = try LoopbackServer()
        let started = Date()

        #expect(throws: StringsmithError.self) {
            try server.waitForCode(state: "S", deadline: Date().addingTimeInterval(0.6))
        }
        // 무한정 붙잡고 있으면 터미널이 먹통이 된다.
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("브라우저에 보여 줄 페이지는 두 경우 모두 문장을 담는다")
    func rendersBothOutcomes() {
        #expect(LoopbackServer.page(success: true).contains("<!doctype html"))
        #expect(LoopbackServer.page(success: false).contains("<!doctype html"))
        #expect(LoopbackServer.page(success: true) != LoopbackServer.page(success: false))
    }

    /// 코드를 받은 시점에 나가는 페이지라 아직 성공을 알 수 없다. 2026-08-10 에 이 페이지가
    /// "로그인되었습니다" 라고 띄운 뒤 토큰 교환이 실패해 터미널과 말이 어긋났다.
    @Test("코드를 받은 페이지는 로그인 성공을 단언하지 않는다")
    func doesNotClaimSuccessBeforeTheExchange() {
        let page = LoopbackServer.page(success: true)
        #expect(page.contains("Signed in") == false)
        #expect(page.contains("로그인되었습니다") == false)
    }
}
