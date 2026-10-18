import CoreAudio
import Foundation

/// Music 재생을 지켜보다가 곡이 실제로 바뀔 때 기본 출력 장치 rate를 맞춘다.
/// - 스트리밍 곡: coremedia 로그 (MusicLogTracker)
/// - 로컬 파일 곡: playerInfo 곡 전환 → AppleScript sample rate
/// - 다음 곡의 rate가 다르다는 걸 미리 알면(prefetch), 현재 곡이 끝나기 직전에 멈추고 바꾼 뒤 다음 곡으로 넘긴다
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

    /// rate를 바꿀 때 Music을 일시정지하고, 장치가 변경을 확인한 뒤 이 시간만큼 더 기다렸다가 재개한다.
    /// 인터페이스가 클럭을 다시 잡는 시간은 Mac 쪽에 신호가 없어서 사용자가 정한다. nil이면 일시정지하지 않는다.
    public var settleDelay: TimeInterval?

    /// 장치가 rate 변경을 확인한 뒤 실행할 준비 확인 스크립트 (ReadyScript 참고).
    /// 끝나면 바로 재생한다. 스크립트가 있으면 settleDelay는 쓰지 않고, 실패하거나
    /// readyScriptTimeout을 넘겨도 따로 기다리지 않는다 (준비 판단은 전적으로 스크립트 몫).
    public var readyScript: URL? {
        didSet { if readyScript != oldValue { lastReadyScriptFailure = nil } }
    }
    public var readyScriptTimeout: TimeInterval = 20

    /// 마지막 준비 확인 스크립트 실행이 실패했으면 그 이유 (성공하거나 스크립트를 바꾸면 nil). 메뉴 표시용.
    public private(set) var lastReadyScriptFailure: String?
    public var readyScriptFallbackDelay: TimeInterval = 0

    /// 곡이 끝나기 이만큼 전에 미리 멈춘다. 새 곡 소리가 잘못된 rate로 한 번도 나가지 않게 하려는 것.
    public var preEndLead: TimeInterval = 0.15

    private let tracker = MusicLogTracker()
    private var switchGeneration = 0
    private var heldPause: MusicScripting.PauseState? {
        didSet {
            guard (oldValue == nil) != (heldPause == nil) else { return }
            onStatusChange?()
        }
    }

    /// 샘플레이트를 바꾸느라 앱이 Music을 일시정지해 둔 동안 true (메뉴바에 쉼표 표시용)
    public var isHoldingPlayback: Bool { heldPause != nil }
    /// 일시정지 → rate 변경 → 대기 → 재개 흐름이 진행 중
    private var switchInFlight = false
    private var rateConfirmed: (() -> Void)?
    private var runningReadyScript: ReadyScript?
    /// 미리 불러온 다음 곡 (rate가 지금과 다를 때만). 곡 끝 직전 일시정지 감시 대상
    private var upcoming: (player: String, item: String, format: MusicLogTracker.Format)?
    private var endWatchGeneration = 0

    private var logProcess: Process?
    private var lastRateWeSet: Double?
    private var lastPersistentID: String?
    /// playerInfo 알림으로 아는 마지막 재생 상태. 곡이 바뀔 때 잠깐 "Stopped"가 끼므로 "Paused"일 때만 멈춰 있다고 본다.
    private var lastPlayerState: String?
    private var watchedDevices = Set<AudioDevice>()
    private var playerInfoObserver: NSObjectProtocol?

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
        tracker.onEvent = { [weak self] event in
            switch event {
            case let .formatLearned(player, item, format):
                guard let self else { return }
                onMessage?(.info(L("Format     P/%@ %@ = %@", player, item, format.description)))
                // 지금 재생 중인 곡이 아닌 곡의 포맷 = 다음 곡 미리 불러오기
                if item != tracker.currentItem(of: player) {
                    upcomingPrepared(player: player, item: item, format: format)
                }
            case let .currentItemChanged(player, from, to):
                self?.onMessage?(.info(L("Track      P/%@ %@ → %@", player, from ?? "-", to ?? "-")))
                self?.disarmEndWatch()
            case let .waitingForFormat(player, item):
                self?.onMessage?(.info(L("Waiting    P/%@ %@", player, item)))
            }
        }
    }

    // MARK: - 입력

    /// coremedia 로그 메시지 한 줄. 실시간 수신과 --replay가 같이 쓴다.
    public func feed(logMessage: String) {
        guard let decision = tracker.handle(logMessage),
              case let .switchTo(player, item, format) = decision else { return }
        // 곡이 바뀐 직후의 판단이므로 멈췄다면 처음부터 다시 재생
        setRate(format.sampleRate, reason: "P/\(player) \(item) \(format.codec)", then: .rewind)
    }

    public func start() throws {
        DispatchQueue.global().async { MusicScripting.warmUp() }
        watchDefaultOutput()
        observePlayerInfo()
        checkCurrentTrackOnStart()
        try startLogStream()
    }

    public func stop() {
        disarmEndWatch()
        runningReadyScript?.cancel()
        logProcess?.terminate()
        logProcess = nil
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
        }
        playerInfoObserver = nil
    }

    // MARK: - 장치

    /// action: 일시정지했다면 재개할 때 할 일
    private func setRate(_ rate: Double, reason: String, then action: MusicScripting.ResumeAction) {
        let newTarget = Target(sampleRate: rate, reason: reason)
        if target != newTarget {
            target = newTarget
            onStatusChange?()
        }
        guard !dryRun else {
            onMessage?(.action("→ rate \(Int(rate))  (\(reason), dry-run)"))
            return
        }
        guard let device = AudioDevice.defaultOutput else {
            onMessage?(.warning(L("No default output device")))
            releaseHold()
            return
        }
        if device.nominalSampleRate == rate {
            onMessage?(.action(L("= rate %ld unchanged  (%@, %@)", Int(rate), device.name, reason)))
            releaseHold()
            return
        }
        guard device.supports(rate) else {
            onMessage?(.warning(L("%@ doesn’t support %ld, skipped", device.name, Int(rate))))
            releaseHold()
            return
        }
        if let settleDelay {
            switchWithPause(device: device, rate: rate, reason: reason, settleDelay: settleDelay, then: action)
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
        onMessage?(.warning(L("Failed to set sample rate, OSStatus=%ld", Int(status))))
        return false
    }

    /// 일시정지 → rate 변경 → 장치 확인 알림 (최대 2초) → settleDelay → 재개
    private func switchWithPause(device: AudioDevice, rate: Double, reason: String, settleDelay: TimeInterval,
                                 then action: MusicScripting.ResumeAction) {
        switchGeneration += 1
        let generation = switchGeneration
        let started = Date()
        switchInFlight = true
        disarmEndWatch()
        runningReadyScript?.cancel()
        runningReadyScript = nil

        let proceed = { [self] in
            // 일시정지하는 동안 더 새로운 전환이 시작됐으면 그쪽에 맡긴다
            guard generation == switchGeneration else { return }
            var finished = false
            let finish = { [self] (confirmed: Bool) in
                guard !finished else { return }
                finished = true
                rateConfirmed = nil
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let readyScript {
                    onMessage?(confirmed
                        ? .info(L("Device confirmed in %ldms, running ready script", ms))
                        : .warning(L("No confirmation from device (%ldms), running ready script", ms)))
                    waitForReadyScript(readyScript, device: device, rate: rate, generation: generation, fallbackDelay: readyScriptFallbackDelay)
                    return
                }
                onMessage?(confirmed
                    ? .info(L("Device confirmed in %ldms, resuming after %ldms", ms, Int(settleDelay * 1000)))
                    : .warning(L("No confirmation from device (%ldms), resuming after %ldms", ms, Int(settleDelay * 1000))))
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

        // 이미 이전 전환 때문에 멈춰 있으면 다시 멈출 필요 없음.
        // 사용자가 일시정지해 둔 상태도 건너뛰되, 곡이 막 바뀐 경우(rewind/advance)는 재생이 시작되는 중이라 반드시 멈춘다.
        // (멈춰 있던 상태에서 새 곡을 재생하면 "Playing" 알림이 포맷 로그보다 늦게 와서 lastPlayerState가 아직 "Paused"다)
        if heldPause != nil || (action == .resume && lastPlayerState == "Paused") {
            proceed()
            return
        }
        // Apple Event를 직접, 응답을 기다리지 않고 보내 바로 멈춘다 (AppleScript 조회 큐와 별개)
        DispatchQueue.global(qos: .userInteractive).async {
            let result = MusicScripting.pauseNow(then: action)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                self.onMessage?(result.paused
                    ? .info(L("Paused in %ldms (%ld tries)", ms, result.attempts))
                    : .warning(L("Couldn’t confirm pause in %ldms (%ld tries)", ms, result.attempts)))
                self.heldPause = result.state
                proceed()
            }
        }
    }

    /// 준비 확인 스크립트가 exit 0으로 끝나면 바로 재개. 실패하면 고정 대기 시간 중 남은 만큼 기다렸다가 재개.
    private func waitForReadyScript(_ url: URL, device: AudioDevice, rate: Double, generation: Int, fallbackDelay: TimeInterval) {
        let started = Date()
        let environment = ["SRS_SAMPLE_RATE": String(Int(rate)), "SRS_DEVICE_UID": device.uid, "SRS_DEVICE_NAME": device.name]
        runningReadyScript = ReadyScript(url: url, environment: environment, timeout: readyScriptTimeout) { [weak self] outcome in
            guard let self, generation == switchGeneration else { return }
            runningReadyScript = nil
            let elapsed = Date().timeIntervalSince(started)
            switch outcome {
            case .ready:
                lastReadyScriptFailure = nil
                onMessage?(.info(L("Ready script finished in %ldms", Int(elapsed * 1000))))
                resumeHeld(generation: generation)
            case .failed(let reason):
                lastReadyScriptFailure = reason
                let remaining = max(fallbackDelay - elapsed, 0)
                if remaining == 0 {
                    onMessage?(.warning(L("Ready script failed (%@), resuming now", reason)))
                    resumeHeld(generation: generation)
                } else {
                    onMessage?(.warning(L("Ready script failed (%@), resuming after %ldms", reason, Int(remaining * 1000))))
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { self.resumeHeld(generation: generation) }
                }
            }
        }
    }

    /// 전환할 필요가 없어졌을 때: 붙잡아 둔 일시정지가 있으면 재개
    private func releaseHold() {
        if heldPause != nil {
            switchGeneration += 1
            resumeHeld(generation: switchGeneration)
        } else {
            switchInFlight = false
        }
    }

    private func resumeHeld(generation: Int) {
        guard generation == switchGeneration else { return }
        switchInFlight = false
        guard let state = heldPause else { return }
        heldPause = nil
        switch state.action {
        case .advance: onMessage?(.info(L("Resumed (next track)")))
        case .rewind: onMessage?(.info(L("Resumed (from the beginning)")))
        case .resume: onMessage?(.info(L("Resumed")))
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let detail = MusicScripting.resume(state)
            DispatchQueue.main.async { self.onMessage?(.info("  " + detail)) }
        }
    }

    // MARK: - 곡 끝 직전 일시정지

    /// 다음 곡의 rate가 지금과 다르면, 현재 곡이 끝나기 직전에 멈추도록 감시를 건다.
    /// 곡이 넘어간 뒤에 멈추면 새 곡 앞부분이 잠깐 새어 나가므로, 넘어가기 전에 멈추는 게 근본 해결.
    private func upcomingPrepared(player: String, item: String, format: MusicLogTracker.Format) {
        guard settleDelay != nil, !dryRun, !switchInFlight else { return }
        guard let device = AudioDevice.defaultOutput,
              device.nominalSampleRate != format.sampleRate, device.supports(format.sampleRate) else {
            disarmEndWatch()
            return
        }
        guard upcoming?.item != item else { return }  // 이미 감시 중
        upcoming = (player, item, format)
        endWatchGeneration += 1
        onMessage?(.info(L("Next track is %ld Hz, will pause just before this one ends", Int(format.sampleRate))))
        checkEnd(generation: endWatchGeneration)
    }

    private func disarmEndWatch() {
        upcoming = nil
        endWatchGeneration += 1
    }

    /// 남은 시간을 보고 다시 확인할 때를 정한다. 끝이 가까우면 정확한 시각에 일시정지.
    /// 탐색(seek)으로 위치가 바뀌어도 따라가도록 멀리 있을 때도 5초마다 다시 본다.
    private func checkEnd(generation: Int) {
        let recheck = { [self] (delay: TimeInterval) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.checkEnd(generation: generation) }
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let state = MusicEvents.playerState
            let position = MusicEvents.playerPosition
            let finish = MusicEvents.currentTrackFinish
            DispatchQueue.main.async { [self] in
                guard generation == endWatchGeneration, let upcoming else { return }
                guard state == .playing, let position, let finish else { return recheck(1) }
                let remaining = finish - position
                if remaining > preEndLead + 0.5 {
                    recheck(min(remaining - preEndLead - 0.4, 5))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(remaining - preEndLead, 0)) { [self] in
                    guard generation == endWatchGeneration, settleDelay != nil else { return }
                    disarmEndWatch()
                    onMessage?(.info(L("Pausing %ldms before the end", Int(min(remaining, preEndLead) * 1000))))
                    let format = upcoming.format
                    setRate(format.sampleRate, reason: "P/\(upcoming.player) \(upcoming.item) \(format.codec)", then: .advance)
                }
            }
        }
    }

    private func watchDefaultOutput() {
        if let device = AudioDevice.defaultOutput {
            onMessage?(.info(L("Device: %@ %ld Hz", device.name, Int(device.nominalSampleRate)) + (dryRun ? "  [dry-run]" : "")))
            watch(device)
        }
        AudioDevice.onDefaultOutputChange { [weak self] in
            guard let self, let device = AudioDevice.defaultOutput else { return }
            onMessage?(.info(L("Default output changed: %@ %ld Hz", device.name, Int(device.nominalSampleRate))))
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
                onMessage?(.warning(L("Sample rate changed externally: %ld  (%@)", Int(rate), device.name)))
            }
            onStatusChange?()
        }
    }

    // MARK: - 로컬 파일 곡 (AppleScript)

    private func observePlayerInfo() {
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            self?.lastPlayerState = note.userInfo?["Player State"] as? String
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
                    self.applyIfLocalFile(track, then: .rewind)
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
                // 앱을 켰을 때 이미 재생 중이던 곡: 곡 중간일 수 있으니 멈춘 자리에서 재개
                self.applyIfLocalFile(track, then: .resume)
            }
        }
    }

    private func applyIfLocalFile(_ track: MusicScripting.CurrentTrack, then action: MusicScripting.ResumeAction) {
        guard track.isLocalFile, track.sampleRate > 0 else { return }
        let file = (track.localPath! as NSString).lastPathComponent
        setRate(track.sampleRate, reason: L("local file %@", file), then: action)
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
                self.onMessage?(.warning(L("log stream ended")))
                self.onStatusChange?()
            }
        }
    }

    public var isRunning: Bool { logProcess?.isRunning == true }
}
