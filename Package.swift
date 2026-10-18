// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "like-losslessswitcher",
    platforms: [.macOS(.v14)],
    targets: [
        // Core Audio 장치 제어 + Music 로그 해석 (곡 ID → 포맷 맵, 곡 전환 감지)
        .target(name: "RateCore"),
        // 프로토타입: log stream을 읽어 곡이 실제로 바뀔 때만 장치 rate 변경. --replay로 캡처 파일 검증
        .executableTarget(name: "switcher", dependencies: ["RateCore"]),
        // 1단계 진단 도구: 장치 rate 변화 + Music 곡 전환을 타임스탬프와 함께 기록
        .executableTarget(name: "ratewatch", dependencies: ["RateCore"]),
    ]
)
