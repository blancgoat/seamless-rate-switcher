import CoreAudio
import Foundation
import RateCore

// 사용법:
//   switcher                 Music 로그를 실시간으로 읽고 곡이 바뀔 때 기본 출력 장치 rate를 맞춘다
//   switcher --dry-run       판단만 출력하고 장치는 건드리지 않는다
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

func say(_ text: String) {
    let ts = logTimestamp.map { String($0.dropFirst(11).prefix(12)) } ?? clock.string(from: Date())
    print("\(ts)  \(text)")
    fflush(stdout)
}

let tracker = MusicLogTracker()
tracker.onEvent = { event in
    switch event {
    case let .formatLearned(player, item, format):
        say("    포맷 기록  P/\(player) \(item) = \(format)")
    case let .currentItemChanged(player, from, to):
        say("    곡 전환    P/\(player) \(from ?? "-") → \(to ?? "-")")
    case let .waitingForFormat(player, item):
        say("    포맷 대기  P/\(player) \(item)")
    }
}

/// 우리가 바꾼 rate. 리스너에서 외부 변경과 구분하는 데 쓴다.
var lastRateWeSet: Double?

func apply(_ decision: MusicLogTracker.Decision) {
    guard case let .switchTo(player, item, format) = decision else { return }
    setRate(format.sampleRate, reason: "P/\(player) \(item) \(format.codec)")
}

func setRate(_ target: Double, reason: String) {
    guard !dryRun else {
        say("→ rate \(Int(target))  (\(reason), dry-run)")
        return
    }
    guard let device = AudioDevice.defaultOutput else {
        say("! 기본 출력 장치 없음")
        return
    }
    if device.nominalSampleRate == target {
        say("= rate \(Int(target)) 유지  (\(device.name), \(reason))")
        return
    }
    guard device.supports(target) else {
        say("! \(device.name)는 \(Int(target))을 지원하지 않음, 건너뜀")
        return
    }
    lastRateWeSet = target
    let status = device.setNominalSampleRate(target)
    say(status == noErr
        ? "→ rate \(Int(target))  (\(device.name), \(reason))"
        : "! rate 변경 실패 OSStatus=\(status)")
}

/// 로컬 파일 곡이면 AppleScript sample rate로 맞춘다. 스트리밍 곡은 로그 쪽(tracker)이 처리.
func applyIfLocalFile(_ track: MusicScripting.CurrentTrack) {
    guard track.isLocalFile, track.sampleRate > 0 else { return }
    let file = (track.localPath! as NSString).lastPathComponent
    setRate(track.sampleRate, reason: "로컬 파일 \(file)")
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
        if let decision = tracker.handle(entry.message) { apply(decision) }
    }
    exit(0)
}

// MARK: - live

func watch(_ device: AudioDevice) {
    device.onChange(kAudioDevicePropertyNominalSampleRate) {
        let rate = device.nominalSampleRate
        if rate == lastRateWeSet {
            lastRateWeSet = nil
        } else {
            say("! 외부에서 rate 변경: \(Int(rate))  (\(device.name))")
        }
    }
}

if let device = AudioDevice.defaultOutput {
    say("장치: \(device.name) \(Int(device.nominalSampleRate)) Hz\(dryRun ? "  [dry-run]" : "")")
    watch(device)
}
AudioDevice.onDefaultOutputChange {
    guard let device = AudioDevice.defaultOutput else { return }
    say("기본 출력 장치 변경: \(device.name) \(Int(device.nominalSampleRate)) Hz")
    watch(device)
}

// 로컬 파일 곡: playerInfo 곡 전환 → AppleScript로 확인
var lastPersistentID: String?
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
) { note in
    // 곡 전환 때 Stopped → Playing 알림이 연달아 오므로 ID가 바뀐 Playing만 본다
    guard note.userInfo?["Player State"] as? String == "Playing",
          let pid = MusicScripting.hexPersistentID(note.userInfo?["PersistentID"]),
          pid != lastPersistentID else { return }
    lastPersistentID = pid
    DispatchQueue.global().async {
        guard let track = MusicScripting.currentTrack(matching: pid) else { return }
        DispatchQueue.main.async {
            // 조회하는 동안 다음 곡으로 넘어갔으면 버린다
            guard lastPersistentID == pid else { return }
            applyIfLocalFile(track)
        }
    }
}

// 시작 시점에 재생 중인 곡이 로컬 파일이면 바로 맞춘다 (스트리밍 곡은 다음 곡 전환부터)
DispatchQueue.global().async {
    guard let track = MusicScripting.currentTrack() else { return }
    DispatchQueue.main.async {
        lastPersistentID = track.persistentID
        applyIfLocalFile(track)
    }
}

let logProcess = Process()
logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
logProcess.arguments = ["stream", "--style", "ndjson", "--predicate", MusicLog.predicate]
let pipe = Pipe()
logProcess.standardOutput = pipe
do {
    try logProcess.run()
} catch {
    say("! log stream 실행 실패: \(error)")
    exit(1)
}

// Ctrl-C / kill 시 log stream도 같이 정리
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        logProcess.terminate()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

Thread.detachNewThread {
    var buffer = Data()
    let handle = pipe.fileHandleForReading
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let entry = MusicLog.parse(ndjsonLine: line) else { continue }
            DispatchQueue.main.async {
                if let decision = tracker.handle(entry.message) { apply(decision) }
            }
        }
    }
    DispatchQueue.main.async {
        say("! log stream 종료됨")
        exit(1)
    }
}

dispatchMain()
