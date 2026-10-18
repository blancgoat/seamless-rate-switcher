import CoreAudio
import Foundation

/// Music 재생을 지켜보다가 곡이 실제로 바뀔 때 기본 출력 장치 rate를 맞춘다.
/// - 스트리밍 곡: coremedia 로그 (MusicLogTracker)
/// - 로컬 파일 곡: playerInfo 곡 전환 → AppleScript sample rate
///
/// 모든 콜백과 상태 변경은 main 큐에서 일어난다.
public final class RateSwitcher {
    public enum Message {
        case info(String)      // 판단 과정 (포맷 기록, 곡 전환 등)
        case action(String)    // rate 변경 / 유지
        case warning(String)   // 실패, 외부 변경 등
    }

    /// 마지막으로 맞추려고 한 rate와 그 이유. 메뉴바 표시용.
    public struct Target: Equatable {
        public let sampleRate: Double
        public let reason: String
    }

    public var onMessage: ((Message) -> Void)?
    /// 장치 rate나 target이 바뀌면 호출
    public var onStatusChange: (() -> Void)?

    public let dryRun: Bool
    public private(set) var target: Target?

    /// 꺼 두면 판단은 계속하되 장치는 건드리지 않는다. 다시 켜면 마지막 target을 적용한다.
    public var isEnabled = true {
        didSet {
            guard isEnabled, !oldValue, let target else { return }
            setRate(target.sampleRate, reason: target.reason)
        }
    }

    private let tracker = MusicLogTracker()
    private var logProcess: Process?
    private var lastRateWeSet: Double?
    private var lastPersistentID: String?
    private var watchedDevices = Set<AudioDevice>()
    private var playerInfoObserver: NSObjectProtocol?

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
        tracker.onEvent = { [weak self] event in
            switch event {
            case let .formatLearned(player, item, format):
                self?.onMessage?(.info("포맷 기록  P/\(player) \(item) = \(format)"))
            case let .currentItemChanged(player, from, to):
                self?.onMessage?(.info("곡 전환    P/\(player) \(from ?? "-") → \(to ?? "-")"))
            case let .waitingForFormat(player, item):
                self?.onMessage?(.info("포맷 대기  P/\(player) \(item)"))
            }
        }
    }

    // MARK: - 입력

    /// coremedia 로그 메시지 한 줄. 실시간 수신과 --replay가 같이 쓴다.
    public func feed(logMessage: String) {
        guard let decision = tracker.handle(logMessage),
              case let .switchTo(player, item, format) = decision else { return }
        setRate(format.sampleRate, reason: "P/\(player) \(item) \(format.codec)")
    }

    public func start() throws {
        watchDefaultOutput()
        observePlayerInfo()
        checkCurrentTrackOnStart()
        try startLogStream()
    }

    public func stop() {
        logProcess?.terminate()
        logProcess = nil
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
        }
        playerInfoObserver = nil
    }

    // MARK: - 장치

    private func setRate(_ rate: Double, reason: String) {
        let newTarget = Target(sampleRate: rate, reason: reason)
        if target != newTarget {
            target = newTarget
            onStatusChange?()
        }
        guard !dryRun else {
            onMessage?(.action("→ rate \(Int(rate))  (\(reason), dry-run)"))
            return
        }
        guard isEnabled else {
            onMessage?(.info("일시중지됨, rate \(Int(rate)) 적용 안 함  (\(reason))"))
            return
        }
        guard let device = AudioDevice.defaultOutput else {
            onMessage?(.warning("기본 출력 장치 없음"))
            return
        }
        if device.nominalSampleRate == rate {
            onMessage?(.action("= rate \(Int(rate)) 유지  (\(device.name), \(reason))"))
            return
        }
        guard device.supports(rate) else {
            onMessage?(.warning("\(device.name)는 \(Int(rate))을 지원하지 않음, 건너뜀"))
            return
        }
        lastRateWeSet = rate
        let status = device.setNominalSampleRate(rate)
        if status == noErr {
            onMessage?(.action("→ rate \(Int(rate))  (\(device.name), \(reason))"))
        } else {
            lastRateWeSet = nil
            onMessage?(.warning("rate 변경 실패 OSStatus=\(status)"))
        }
    }

    private func watchDefaultOutput() {
        if let device = AudioDevice.defaultOutput {
            onMessage?(.info("장치: \(device.name) \(Int(device.nominalSampleRate)) Hz\(dryRun ? "  [dry-run]" : "")"))
            watch(device)
        }
        AudioDevice.onDefaultOutputChange { [weak self] in
            guard let self, let device = AudioDevice.defaultOutput else { return }
            onMessage?(.info("기본 출력 장치 변경: \(device.name) \(Int(device.nominalSampleRate)) Hz"))
            watch(device)
            onStatusChange?()
        }
    }

    private func watch(_ device: AudioDevice) {
        guard watchedDevices.insert(device).inserted else { return }
        device.onChange(kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self else { return }
            let rate = device.nominalSampleRate
            if rate == lastRateWeSet {
                lastRateWeSet = nil
            } else {
                onMessage?(.warning("외부에서 rate 변경: \(Int(rate))  (\(device.name))"))
            }
            onStatusChange?()
        }
    }

    // MARK: - 로컬 파일 곡 (AppleScript)

    private func observePlayerInfo() {
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            // 곡 전환 때 Stopped → Playing 알림이 연달아 오므로 ID가 바뀐 Playing만 본다
            guard let self,
                  note.userInfo?["Player State"] as? String == "Playing",
                  let pid = MusicScripting.hexPersistentID(note.userInfo?["PersistentID"]),
                  pid != lastPersistentID else { return }
            lastPersistentID = pid
            DispatchQueue.global().async {
                guard let track = MusicScripting.currentTrack(matching: pid) else { return }
                DispatchQueue.main.async {
                    // 조회하는 동안 다음 곡으로 넘어갔으면 버린다
                    guard self.lastPersistentID == pid else { return }
                    self.applyIfLocalFile(track)
                }
            }
        }
    }

    /// 시작 시점에 재생 중인 곡이 로컬 파일이면 바로 맞춘다 (스트리밍 곡은 다음 곡 전환부터)
    private func checkCurrentTrackOnStart() {
        DispatchQueue.global().async {
            guard let track = MusicScripting.currentTrack() else { return }
            DispatchQueue.main.async {
                self.lastPersistentID = track.persistentID
                self.applyIfLocalFile(track)
            }
        }
    }

    private func applyIfLocalFile(_ track: MusicScripting.CurrentTrack) {
        guard track.isLocalFile, track.sampleRate > 0 else { return }
        let file = (track.localPath! as NSString).lastPathComponent
        setRate(track.sampleRate, reason: "로컬 파일 \(file)")
    }

    // MARK: - 스트리밍 곡 (log stream)

    private func startLogStream() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", MusicLog.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        logProcess = process

        Thread.detachNewThread { [weak self] in
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
                    DispatchQueue.main.async { self?.feed(logMessage: entry.message) }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.logProcess === process else { return }  // stop()으로 끈 경우는 조용히
                self.logProcess = nil
                self.onMessage?(.warning("log stream 종료됨"))
                self.onStatusChange?()
            }
        }
    }

    public var isRunning: Bool { logProcess?.isRunning == true }
}
