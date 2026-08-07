// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stringsmith",
    // 미리보기 앱 UI 를 시스템 언어에 맞춰 보여주기 위해 필요하다.
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "stringsmith", targets: ["stringsmith"]),
        .executable(name: "StringsmithPreview", targets: ["StringsmithPreview"]),
        .library(name: "StringsmithCore", targets: ["StringsmithCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // 코어: 자료구조만 반환한다. 출력·프린트 지식을 갖지 않는다.
        .target(
            name: "StringsmithCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // CLI: 얇은 래퍼. 인자 파싱 + 리포팅만 담당한다.
        .executableTarget(
            name: "stringsmith",
            dependencies: [
                "StringsmithCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 번역 확인 앱. 코어를 직접 링크해 시트를 그 자리에서 읽는다.
        //
        // 예전에는 프로젝트마다 SPM 패키지를 **생성**했지만, 그러면 시트가 바뀔 때마다
        // 재생성·재빌드가 필요하고 여러 프로젝트를 한 창에서 볼 수도 없다.
        .executableTarget(
            name: "StringsmithPreview",
            dependencies: ["StringsmithCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StringsmithCoreTests",
            dependencies: ["StringsmithCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
