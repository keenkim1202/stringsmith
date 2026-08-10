import Compression
import Foundation

/// ZIP 안의 파일 하나를 꺼내는 최소한의 읽기 전용 구현.
///
/// `.xlsx` 는 XML 몇 개를 담은 ZIP 이다. 이걸 읽자고 패키지를 하나 들이는 대신 직접 푼다 —
/// 이 프로젝트는 의존성 0 을 유지한다(`Configuration.swift` 참고). 압축 해제만은 직접 짜지
/// 않고 시스템 `Compression` 프레임워크를 쓴다. 그건 외부 패키지가 아니라 OS 의 일부다.
///
/// **쓰기는 없다.** 아카이브를 만들 일이 없고, 없는 기능은 틀릴 일도 없다.
public struct ZipArchive {

    /// 이름 → 압축 해제된 내용.
    let entries: [String: Data]

    public init(data: Data) throws {
        entries = try Self.read(data)
    }

    public init(path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StringsmithError.io(
                path: path, reason: tr("Could not read the file.", "파일을 읽지 못했습니다."))
        }
        try self.init(data: data)
    }

    public func contents(of name: String) -> Data? { entries[name] }

    public var names: [String] { entries.keys.sorted() }

    // MARK: - 읽기

    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let directory = locateCentralDirectory(bytes) else {
            throw StringsmithError.io(
                path: "zip",
                reason: tr(
                    "Not a ZIP archive (no end-of-central-directory record).",
                    "ZIP 아카이브가 아닙니다 (중앙 디렉터리 끝 표지가 없습니다)."))
        }

        var out: [String: Data] = [:]
        var offset = directory.offset

        for _ in 0..<directory.count {
            guard offset + 46 <= bytes.count,
                readUInt32(bytes, offset) == 0x0201_4B50
            else { break }

            let method = readUInt16(bytes, offset + 10)
            let compressed = Int(readUInt32(bytes, offset + 20))
            let uncompressed = Int(readUInt32(bytes, offset + 24))
            let nameLength = Int(readUInt16(bytes, offset + 28))
            let extraLength = Int(readUInt16(bytes, offset + 30))
            let commentLength = Int(readUInt16(bytes, offset + 32))
            let localOffset = Int(readUInt32(bytes, offset + 42))

            guard offset + 46 + nameLength <= bytes.count else { break }
            let name = String(
                decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            // ZIP64 는 크기 자리에 0xFFFFFFFF 를 두고 확장 필드에 진짜 값을 넣는다.
            // 스프레드시트가 4GB 를 넘을 일은 없으니 지원하지 않되, 조용히 깨지지는 않게 한다.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF
            {
                throw StringsmithError.io(
                    path: name,
                    reason: tr(
                        "ZIP64 archives are not supported.", "ZIP64 아카이브는 지원하지 않습니다."))
            }

            if let payload = try extract(
                bytes, localOffset: localOffset, method: method,
                compressed: compressed, uncompressed: uncompressed, name: name)
            {
                out[name] = payload
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        return out
    }

    /// 로컬 헤더를 지나 실제 데이터를 꺼내 푼다.
    ///
    /// 중앙 디렉터리의 이름 길이와 로컬 헤더의 것이 다를 수 있어서(확장 필드가 다르게 붙는다)
    /// 데이터 시작 위치는 **로컬 헤더에서 다시 읽는다.**
    static func extract(
        _ bytes: [UInt8], localOffset: Int, method: UInt16,
        compressed: Int, uncompressed: Int, name: String
    ) throws -> Data? {
        guard localOffset + 30 <= bytes.count,
            readUInt32(bytes, localOffset) == 0x0403_4B50
        else { return nil }

        let nameLength = Int(readUInt16(bytes, localOffset + 26))
        let extraLength = Int(readUInt16(bytes, localOffset + 28))
        let start = localOffset + 30 + nameLength + extraLength
        guard start + compressed <= bytes.count else { return nil }

        // 디렉터리 항목은 내용이 없다.
        if name.hasSuffix("/") { return nil }

        let payload = Array(bytes[start..<(start + compressed)])
        switch method {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(payload, expecting: uncompressed, name: name)
        default:
            throw StringsmithError.io(
                path: name,
                reason: tr(
                    "Unsupported compression method \(method).",
                    "지원하지 않는 압축 방식입니다 (\(method))."))
        }
    }

    /// raw deflate 를 푼다.
    ///
    /// Apple 의 `COMPRESSION_ZLIB` 은 이름과 달리 zlib 헤더 없는 raw deflate 다 — ZIP 이
    /// 담는 것과 같은 형식이다.
    static func inflate(_ bytes: [UInt8], expecting size: Int, name: String) throws -> Data {
        // 크기가 0 이면 빈 파일이다. 버퍼를 0 으로 잡으면 API 가 실패를 돌려준다.
        guard size > 0 else { return Data() }

        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            guard let base = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return bytes.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    base, size, source.baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else {
            throw StringsmithError.io(
                path: name,
                reason: tr(
                    "The entry could not be decompressed.", "항목의 압축을 풀지 못했습니다."))
        }
        return out
    }

    // MARK: - 중앙 디렉터리 찾기

    /// 끝에서부터 EOCD 표지를 찾는다.
    ///
    /// 뒤에 주석이 붙을 수 있어 파일 맨 끝에 있다는 보장이 없다. 주석 길이는 2바이트라
    /// 최대 64KB 만 거슬러 보면 된다.
    static func locateCentralDirectory(_ bytes: [UInt8]) -> (offset: Int, count: Int)? {
        let minimum = 22
        guard bytes.count >= minimum else { return nil }
        let limit = max(0, bytes.count - minimum - 0xFFFF)

        var index = bytes.count - minimum
        while index >= limit {
            if readUInt32(bytes, index) == 0x0605_4B50 {
                return (Int(readUInt32(bytes, index + 16)), Int(readUInt16(bytes, index + 10)))
            }
            index -= 1
        }
        return nil
    }

    // MARK: - 리틀엔디언 읽기

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
