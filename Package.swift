// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "seamless-rate-switcher",
    platforms: [.macOS(.v14)],
    targets: [
        // Core Audio 장치 제어 + Music 로그 해석 (곡 ID → 포맷 맵, 곡 전환 감지)
        .target(name: "RateCore"),
        // 음표 도형 (메뉴바 아이콘 + 앱 아이콘 공용)
        .target(name: "NoteGlyph"),
        // 메뉴바 앱. scripts/bundle.sh로 .app 번들을 만든다
        .executableTarget(name: "SeamlessRateSwitcher", dependencies: ["RateCore", "NoteGlyph"]),
        // 준비 확인 스크립트 예: MOTU Gen 5 장치의 출력 준비 신호를 기다린다 (앱과 별도로 빌드해서 메뉴에서 선택)
        .executableTarget(name: "motu-ready"),
        // 앱 아이콘 iconset 생성 (bundle.sh가 호출)
        .executableTarget(name: "iconmaker", dependencies: ["NoteGlyph"]),
        // 프로토타입: log stream을 읽어 곡이 실제로 바뀔 때만 장치 rate 변경. --replay로 캡처 파일 검증
        .executableTarget(name: "switcher", dependencies: ["RateCore"]),
        // 1단계 진단 도구: 장치 rate 변화 + Music 곡 전환을 타임스탬프와 함께 기록
        .executableTarget(name: "ratewatch", dependencies: ["RateCore"]),
    ]
)
