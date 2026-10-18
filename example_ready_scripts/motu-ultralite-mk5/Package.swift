// swift-tools-version:5.10
import PackageDescription

// Seamless Rate Switcher의 준비 확인 스크립트: MOTU UltraLite mk5의 출력 준비 신호를 기다린다.
// 앱과 독립된 패키지라 앱 빌드에 포함되지 않는다. build.sh로 빌드한다.
let package = Package(
    name: "motu-ultralite-mk5",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "motu-ultralite-mk5"),
    ]
)
