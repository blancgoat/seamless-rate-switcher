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

    /// rate를 바꿀 때 Music을 일시정지하고, 장치가 변경을 확인한 뒤 이 시간만큼 더 기다렸다가 재개한다.
    /// 인터페이스가 클럭을 다시 잡는 시간은 Mac 쪽에 신호가 없어서 사용자가 정한다. nil이면 일시정지하지 않는다.
    public var settleDelay: TimeInterval?

    /// 일시정지 시점의 곡 위치가 이보다 앞이면 곡 처음으로 되돌린다 (감지 지연 동안 잘못 나간 앞부분 복구)
    public var rewindThreshold: TimeInterval = 3

    private let tracker = MusicLogTracker()
    private var switchGeneration = 0
    private var heldPause: MusicScripting.PauseState?
    private var rateConfirmed: (() -> Void)?
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
                self?.onMessage?(.info("Format     P/\(player) \(item) = \(format)"))
            case let .currentItemChanged(player, from, to):
                self?.onMessage?(.info("Track      P/\(player) \(from ?? "-") → \(to ?? "-")"))
            case let .waitingForFormat(player, item):
                self?.onMessage?(.info("Waiting    P/\(player) \(item)"))
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
            onMessage?(.info("Auto switch off, not applying \(Int(rate))  (\(reason))"))
            return
        }
        guard let device = AudioDevice.defaultOutput else {
            onMessage?(.warning("No default output device"))
            return
        }
        if device.nominalSampleRate == rate {
            onMessage?(.action("= rate \(Int(rate)) unchanged  (\(device.name), \(reason))"))
            // 이전 전환을 기다리는 도중 원래 rate로 돌아온 경우, 붙잡아 둔 일시정지를 풀어 준다
            if heldPause != nil {
                switchGeneration += 1
                resumeHeld(generation: switchGeneration)
            }
            return
        }
        guard device.supports(rate) else {
            onMessage?(.warning("\(device.name) doesn’t support \(Int(rate)), skipped"))
            return
        }
        if let settleDelay {
            switchWithPause(device: device, rate: rate, reason: reason, settleDelay: settleDelay)
        } else {
            applyRate(device: device, rate: rate, reason: reason)
        }
    }

    @discardableResult
    private func applyRate(device: AudioDevice, rate: Double, reason: String) -> Bool {
        lastRateWeSet = rate
        let status = device.setNominalSampleRate(rate)
        if status == noErr {
            onMessage?(.action("→ rate \(Int(rate))  (\(device.name), \(reason))"))
            return true
        }
        lastRateWeSet = nil
        onMessage?(.warning("Failed to set sample rate, OSStatus=\(status)"))
        return false
    }

    /// 일시정지 → rate 변경 → 장치 확인 알림 (최대 2초) → settleDelay → 재개
    private func switchWithPause(device: AudioDevice, rate: Double, reason: String, settleDelay: TimeInterval) {
        switchGeneration += 1
        let generation = switchGeneration
        let started = Date()

        let proceed = { [self] in
            // 일시정지하는 동안 더 새로운 전환이 시작됐으면 그쪽에 맡긴다
            guard generation == switchGeneration else { return }
            var finished = false
            let finish = { [self] (confirmed: Bool) in
                guard !finished else { return }
                finished = true
                rateConfirmed = nil
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                onMessage?(confirmed
                    ? .info("Device confirmed in \(ms)ms, resuming after \(Int(settleDelay * 1000))ms")
                    : .warning("No confirmation from device (\(ms)ms), resuming after \(Int(settleDelay * 1000))ms"))
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { self.resumeHeld(generation: generation) }
            }
            rateConfirmed = { finish(true) }
            guard applyRate(device: device, rate: rate, reason: reason) else {
                rateConfirmed = nil
                resumeHeld(generation: generation)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
        }

        // 이미 이전 전환 때문에 멈춰 있으면 다시 멈출 필요 없음
        if heldPause != nil {
            proceed()
            return
        }
        DispatchQueue.global().async {
            let state = MusicScripting.pauseIfPlaying()
            DispatchQueue.main.async {
                if let state { self.heldPause = state }
                proceed()
            }
        }
    }

    private func resumeHeld(generation: Int) {
        guard generation == switchGeneration, let state = heldPause else { return }
        heldPause = nil
        let rewind = state.position < rewindThreshold
        onMessage?(.info(rewind ? "Resumed (from the beginning)" : "Resumed"))
        DispatchQueue.global().async { MusicScripting.resume(state, rewind: rewind) }
    }

    private func watchDefaultOutput() {
        if let device = AudioDevice.defaultOutput {
            onMessage?(.info("Device: \(device.name) \(Int(device.nominalSampleRate)) Hz\(dryRun ? "  [dry-run]" : "")"))
            watch(device)
        }
        AudioDevice.onDefaultOutputChange { [weak self] in
            guard let self, let device = AudioDevice.defaultOutput else { return }
            onMessage?(.info("Default output changed: \(device.name) \(Int(device.nominalSampleRate)) Hz"))
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
                rateConfirmed?()
            } else {
                onMessage?(.warning("Sample rate changed externally: \(Int(rate))  (\(device.name))"))
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
        setRate(track.sampleRate, reason: "local file \(file)")
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
                self.onMessage?(.warning("log stream ended"))
                self.onStatusChange?()
            }
        }
    }

    public var isRunning: Bool { logProcess?.isRunning == true }
}
