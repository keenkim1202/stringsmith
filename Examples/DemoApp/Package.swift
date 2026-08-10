// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DemoApp",
    defaultLocalization: "ko",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DemoApp",
            // `.lproj` 를 통째로 넘긴다.
            //
            // **SPM 은 `.xcstrings` 를 컴파일하지 않는다.** 리소스로 넣으면 그대로 복사만
            // 되어 런타임에 키가 그대로 화면에 나온다. String Catalog 를 처리하는 건
            // Xcode 프로젝트의 빌드 단계이지 SwiftPM 이 아니다. 그래서 이 예제는
            // `--format strings` 로 만든다.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
