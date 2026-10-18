import Foundation
import RateCore

// 사용법:
//   switcher                 Music 로그를 실시간으로 읽고 곡이 바뀔 때 기본 출력 장치 rate를 맞춘다
//   switcher --dry-run       판단만 출력하고 장치는 건드리지 않는다
//   switcher --settle MS     rate를 바꿀 때 Music을 일시정지하고, 장치 확인 후 MS만큼 더 기다렸다가 재개
//   switcher --replay FILE   capture.sh가 저장한 music.ndjson을 재생해 판단을 검증한다 (장치는 건드리지 않음)

let args = CommandLine.arguments
let replayPath = args.firstIndex(of: "--replay").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let dryRun = args.contains("--dry-run") || replayPath != nil

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// replay 때는 로그의 시각을, 실시간일 때는 현재 시각을 찍는다.
var logTimestamp: String?

let switcher = RateSwitcher(dryRun: dryRun)
if let i = args.firstIndex(of: "--settle"), args.indices.contains(i + 1), let ms = Double(args[i + 1]) {
    switcher.settleDelay = ms / 1000
}
switcher.onMessage = { message in
    let ts = logTimestamp.map { String($0.dropFirst(11).prefix(12)) } ?? clock.string(from: Date())
    switch message {
    case let .info(text): print("\(ts)      \(text)")
    case let .action(text): print("\(ts)  \(text)")
    case let .warning(text): print("\(ts)  ! \(text)")
    }
    fflush(stdout)
}

// MARK: - replay

if let replayPath {
    guard let text = try? String(contentsOfFile: replayPath, encoding: .utf8) else {
        FileHandle.standardError.write("파일을 읽을 수 없음: \(replayPath)\n".data(using: .utf8)!)
        exit(1)
    }
    for line in text.split(separator: "\n") {
        // 실시간 predicate와 같은 범위만 본다
        guard let entry = MusicLog.parse(ndjsonLine: String(line)),
              entry.subsystem == "com.apple.coremedia" else { continue }
        logTimestamp = entry.timestamp
        switcher.feed(logMessage: entry.message)
    }
    exit(0)
}

// MARK: - live

do {
    try switcher.start()
} catch {
    print("log stream 실행 실패: \(error)")
    exit(1)
}

// Ctrl-C / kill 시 log stream도 같이 정리
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        switcher.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
