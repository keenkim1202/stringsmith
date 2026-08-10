import Foundation

/// 요청 하나를 보내고 응답을 돌려준다. 테스트에서는 가짜 구현을 넣는다.
public typealias HTTPFetch = @Sendable (URLRequest) throws -> SheetResponse

/// `URLSession` 기본 구현.
///
/// CLI 는 동기 흐름이라 세마포어로 기다린다. `URLSession.shared` 는 완료를 자체 큐에서
/// 전달하므로 메인 스레드에서 기다려도 교착이 생기지 않는다.
public func performRequest(_ request: URLRequest) throws -> SheetResponse {
    final class Box: @unchecked Sendable {
        var result: Result<SheetResponse, Error>?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error {
            box.result = .failure(error)
            return
        }
        let http = response as? HTTPURLResponse
        box.result = .success(
            SheetResponse(
                status: http?.statusCode ?? 0,
                mimeType: http?.mimeType,
                body: data ?? Data()
            ))
    }
    task.resume()
    done.wait()

    switch box.result {
    case let .success(response): return response
    case let .failure(error): throw error
    case nil:
        throw StringsmithError.io(
            path: request.url?.absoluteString ?? "",
            reason: tr("No response.", "응답을 받지 못했습니다."))
    }
}

// MARK: - 인코딩 도우미

extension Data {
    /// base64url — `+/` 를 `-_` 로 바꾸고 패딩을 뗀다. PKCE 와 JWT 가 쓰는 형식이다.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `application/x-www-form-urlencoded` 본문.
///
/// `.urlQueryAllowed` 는 `+` 와 `&` 를 통과시켜 값이 깨진다. RFC 3986 의 unreserved 만 남긴다.
func formEncoded(_ parameters: [String: String]) -> Data {
    var unreserved = CharacterSet.alphanumerics
    unreserved.insert(charactersIn: "-._~")

    let pairs = parameters.map { key, value -> String in
        let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        return "\(k)=\(v)"
    }
    // 정렬해 두면 테스트에서 본문을 그대로 비교할 수 있다.
    return Data(pairs.sorted().joined(separator: "&").utf8)
}
