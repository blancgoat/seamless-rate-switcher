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
        case detail(String)    // 진단용 세부 과정 (곡 전환, 포맷 기록, 재개 직전 곡 ID 등)
        case info(String)      // 일시정지·재개, 스크립트 결과 등
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
    /// 0이어도 새지 않는다: 일시정지는 보낸 뒤 약 5ms면 먹히고, 포맷이 다른 곡 사이에는 Music이 오디오 출력을
    /// 새로 만드느라 약 40ms 틈이 생겨 그 안에 멈춘다 (실측: 다음 곡은 15ms 남짓만 출력, 들리지 않음).
    /// 이전 150ms는 "일시정지 확인" 폴링 시간을 지연으로 보고 잡은 값이라 곡 끝이 그만큼 잘렸다.
    public var preEndLead: TimeInterval = 0

    /// AutoMix·크로스페이드 겹치기가 시작되기 이만큼 전에 멈춘다. 곡 끝과 달리 여기는 늦으면 안 된다:
    /// 겹치기가 시작된 뒤(OverlappedTransitionState)에 일시정지가 닿으면 Music은 전환을 취소하고 떠나던 곡을
    /// 다시 불러와 그 위치로 되돌린다. 그러면 다시 재생할 때 같은 겹치기 지점에서 또 멈춰 다음 곡으로 영영 넘어가지 못한다
    /// (실측: 겹치기 시작 16ms 뒤에 일시정지가 닿아 같은 곡이 반복됨). 겹치는 구간 앞부분이라 잘려도 티가 안 난다.
    /// 150ms는 1.2.1까지 곡 끝에도 쓰던 값이다.
    public var transitionLead: TimeInterval = 0.15

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

    /// 일시정지하고 rate를 바꾸는 전환이 지금 어느 단계인지 (메뉴바 자세히 표시용)
    public enum Phase: Equatable {
        case idle
        /// Music 일시정지를 보내고 확인하는 중
        case pausing(to: Double)
        /// rate를 보냈고 CoreAudio가 장치 rate가 바뀌었다고 알려 주기를 기다리는 중 (최대 2초)
        case confirming(to: Double)
        /// 고정 대기 시간 (준비 확인 스크립트가 실패했을 때 남은 대기 포함)
        case settling(to: Double, until: Date)
        /// 준비 확인 스크립트 실행 중
        case readyScript(to: Double)
    }
    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onStatusChange?() } }
    }

    /// 마지막 전환이 어떻게 끝났는지. phase가 idle로 돌아가기 직전에 정한다 (메뉴바 자세히 표시용)
    public enum Outcome: Equatable {
        /// 장치 확인과 준비(대기 또는 스크립트)를 마치고 재개
        case ready
        /// 재개는 했지만 준비됐는지 확실하지 않다: 스크립트 실패, 장치 확인 알림 없음, rate 변경 실패
        case uncertain(String)
        /// 전환할 필요가 없어져 중간에 그만뒀다
        case cancelled
    }
    public private(set) var lastOutcome: Outcome = .ready
    /// 진행 중인 전환이 지금까지 겪은 문제 (끝날 때 lastOutcome이 된다)
    private var pendingOutcome: Outcome = .ready

    /// Music이 미리 불러온 다음 곡의 rate. 곡이 바뀌면 지운다 (메뉴바 자세히 표시용)
    public private(set) var nextRate: Double? {
        didSet { if nextRate != oldValue { onStatusChange?() } }
    }

    /// 재개할 때 할 일. 가장 최근 전환이 정한 값이고, 붙잡는 동안 곡이 실제로 바뀌면 advance → rewind로 바뀐다.
    /// (일시정지 결과는 늦게 돌아올 수 있어서, 결과에 담긴 action 대신 이 값을 따른다)
    private var resumeAction: MusicScripting.ResumeAction = .resume
    /// 일시정지 → rate 변경 → 대기 → 재개 흐름이 진행 중
    private var switchInFlight = false
    /// 진행 중인 전환이 맞추는 rate
    private var inFlightRate: Double?
    private var rateConfirmed: (() -> Void)?
    /// 전환을 시작하며 음소거한 장치와 element. 곡을 넘기면 Music이 일시정지를 새 곡 소리가 나가기 시작한 뒤에야
    /// 적용해서(앱의 일시정지 명령은 그 전에 도착한다) 새 곡 앞부분이 잠깐 들린다. 장치 음소거는 Music을 거치지 않아 그 전에 걸린다.
    private var mutedForSwitch: (device: AudioDevice, elements: [UInt32])?
    private static let mutedForSwitchKey = "mutedForSwitch"
    private var runningReadyScript: ReadyScript?
    /// 미리 불러온 다음 곡 (rate가 지금과 다를 때만). 곡 끝 직전 일시정지 감시 대상
    private var upcoming: (player: String, item: String, format: MusicLogTracker.Format)?
    private var endWatchGeneration = 0

    /// 곡 전환 효과(AutoMix·크로스페이드)의 계획: 지금 곡의 어디서부터 다음 곡과 겹치는지. 곡 끝 대신 여기 직전에 멈춘다.
    /// Music이 곡(item)마다 겹치기 시작 위치를 알려 준다. 다음 곡 것이 먼저 오기도 해서 곡별로 둔다.
    private var overlapStarts: [String: TimeInterval] = [:]
    private var transitionStart: TimeInterval? {
        tracker.currentItems.values.lazy.compactMap { self.overlapStarts[$0] }.first
    }
    /// 곡 전환 효과가 진행 중. 이때 일시정지하면 Music이 전환을 취소하고 이전 곡을 다시 불러오며 꼬이므로,
    /// 그동안 필요해진 rate 변경은 전환이 끝난 뒤로 미룬다.
    private var inTransition = false
    private var transitionGeneration = 0
    private var afterTransition: (rate: Double, reason: String)?
    /// 전환하는 동안 Music이 미리 불러온 다음 곡. 전환이 끝나면 곡 끝 감시를 건다
    /// (지금 곡으로 바꾸느라 준비 확인 스크립트를 기다리는 몇 초 사이에 다음 곡을 불러오는 일이 흔하다.
    /// 그대로 버리면 다음 곡 rate가 달라도 미리 멈추지 못하고, 곡 전환 효과가 이미 시작된 뒤에야 바꾼다)
    private var upcomingDuringSwitch: (player: String, item: String, format: MusicLogTracker.Format)?

    private var logProcess: Process?
    /// 켤 때 지난 로그를 다시 읽는 중. 그동안 실시간으로 들어온 로그는 모아 뒀다가 다 읽은 뒤 순서대로 처리한다
    private var replayingRecentLog = false
    private var liveDuringReplay: [String] = []
    /// 다시 읽는 동안 알게 된 다음 곡. 지금 곡의 rate를 먼저 맞춘 뒤에 곡 끝 감시를 건다
    /// (감시를 걸지는 "다음 곡 rate ≠ 장치 rate"로 정하는데, 장치 rate가 곧 바뀌기 때문)
    private var upcomingDuringReplay: (player: String, item: String, format: MusicLogTracker.Format)?
    private var lastRateWeSet: Double?
    private var lastPersistentID: String?
    /// playerInfo 알림으로 아는 마지막 재생 상태. 곡이 바뀔 때 잠깐 "Stopped"가 끼므로 "Paused"일 때만 멈춰 있다고 본다.
    private var lastPlayerState: String?
    /// 앱이 일시정지해 둔 동안 다른 쪽(Music 창·키보드·다른 앱)이 다시 재생했다. 그러면 재개할 때 다음 곡으로
    /// 넘기거나 처음으로 되감지 않는다 (사용자가 고른 재생을 덮어쓰게 된다)
    private var resumedByOtherDuringHold = false
    private var watchedDevices = Set<AudioDevice>()
    private var playerInfoObserver: NSObjectProtocol?

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
        tracker.onEvent = { [weak self] event in
            switch event {
            case let .formatLearned(player, item, format):
                guard let self else { return }
                onMessage?(.detail(L("Format     P/%@ %@ = %@", player, item, format.description)))
                // 지금 재생 중인 곡이 아닌 곡의 포맷 = 다음 곡 미리 불러오기
                if item != tracker.currentItem(of: player) {
                    nextRate = format.sampleRate
                    upcomingPrepared(player: player, item: item, format: format)
                }
            case let .currentItemChanged(player, from, to):
                guard let self else { return }
                onMessage?(.detail(L("Track      P/%@ %@ → %@", player, from ?? "-", to ?? "-")))
                disarmEndWatch()
                upcomingDuringSwitch = nil
                upcomingDuringReplay = nil
                nextRate = nil
                // 떠난 곡의 계획은 더 쓰지 않는다
                if let from { overlapStarts[from] = nil }
                // 곡 끝 직전에 멈췄는데 그사이 Music이 스스로 다음 곡으로 넘어갔다면, 재개할 때 또 넘기면 안 된다
                if resumeAction == .advance { resumeAction = .rewind }
            case let .waitingForFormat(player, item):
                self?.onMessage?(.detail(L("Waiting    P/%@ %@", player, item)))
            }
        }
    }

    // MARK: - 입력

    /// coremedia 로그 메시지 한 줄. 실시간 수신과 --replay가 같이 쓴다.
    public func feed(logMessage: String) {
        if let transition = MusicLog.transition(logMessage) {
            handle(transition)
            return
        }
        guard let decision = tracker.handle(logMessage) else { return }
        let player: String, item: String, format: MusicLogTracker.Format, action: MusicScripting.ResumeAction
        switch decision {
        case let .switchTo(p, i, f):
            // 곡이 바뀐 직후의 판단이므로 멈췄다면 처음부터 다시 재생
            (player, item, format, action) = (p, i, f, .rewind)
        case let .formatChanged(p, i, f):
            // 곡이 막 바뀌어 아직 붙잡고 있으면 그 전환이 정한 대로 재개하고, 곡 중간이면 멈춘 자리에서 재개
            (player, item, format, action) = (p, i, f, switchInFlight || heldPause != nil ? resumeAction : .resume)
        }
        let reason = "P/\(player) \(item) \(format.codec)"
        if inTransition && settleDelay != nil && AudioDevice.defaultOutput?.nominalSampleRate != format.sampleRate {
            afterTransition = (format.sampleRate, reason)
            onMessage?(.info(L("Song transition in progress, switching after it ends")))
            return
        }
        setRate(format.sampleRate, reason: reason, then: action)
    }

    public func start() throws {
        DispatchQueue.global().async { MusicScripting.warmUp() }
        restoreMuteLeftOver()
        watchDefaultOutput()
        observePlayerInfo()
        checkCurrentTrackOnStart()
        replayingRecentLog = true
        try startLogStream()
        replayRecentLog()
    }

    public func stop() {
        unmuteAfterSwitch()
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
        // 이 rate로 바꾸는 전환이 진행 중인데 같은 rate 곡으로 넘어갔다: Music은 넘긴 곡을 바로 재생하므로
        // 다시 멈추고, 진행 중인 기다림이 끝나면 함께 재개한다. 일시정지를 확인하느라 아직 rate를 보내기 전이어도
        // 그 전환이 곧 보내므로 새로 바꾸지 않는다 (장치는 아직 이전 rate라 장치 값으로는 판단할 수 없다)
        if switchInFlight, inFlightRate == rate, action != .resume {
            onMessage?(.action(L("= rate %ld unchanged, still waiting for the device  (%@, %@)", Int(rate), device.name, reason)))
            holdAgain(then: action)
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
        inFlightRate = rate
        resumeAction = action
        phase = .pausing(to: rate)
        pendingOutcome = .ready
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
                // 확인을 기다리는 사이 더 새로운 전환이 시작됐으면 그쪽에 맡긴다 (늦게 온 시간 초과로 단계를 덮어쓰지 않게)
                guard generation == switchGeneration else { return }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if !confirmed { pendingOutcome = .uncertain(L("No confirmation from the device")) }
                if let readyScript {
                    phase = .readyScript(to: rate)
                    onMessage?(confirmed
                        ? .info(L("Device confirmed in %ldms, running ready script", ms))
                        : .warning(L("No confirmation from device (%ldms), running ready script", ms)))
                    waitForReadyScript(readyScript, device: device, rate: rate, generation: generation, fallbackDelay: readyScriptFallbackDelay)
                    return
                }
                onMessage?(confirmed
                    ? .info(L("Device confirmed in %ldms, resuming after %ldms", ms, Int(settleDelay * 1000)))
                    : .warning(L("No confirmation from device (%ldms), resuming after %ldms", ms, Int(settleDelay * 1000))))
                phase = .settling(to: rate, until: Date().addingTimeInterval(settleDelay))
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { self.resumeHeld(generation: generation) }
            }
            rateConfirmed = { finish(true) }
            phase = .confirming(to: rate)
            guard applyRate(device: device, rate: rate, reason: reason) else {
                rateConfirmed = nil
                pendingOutcome = .uncertain(L("Couldn’t set the sample rate"))
                resumeHeld(generation: generation)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
        }

        // 이미 이전 전환 때문에 멈춰 있거나 사용자가 일시정지해 둔 상태면 멈출 필요 없다.
        // 단, 곡이 막 바뀐 경우(rewind/advance)는 재생이 시작되는 중이라 반드시 멈춘다:
        // - 멈춰 있던 상태에서 새 곡을 재생하면 "Playing" 알림이 포맷 로그보다 늦게 와서 lastPlayerState가 아직 "Paused"다
        // - 붙잡아 둔 동안 사용자가 다른 곡으로 넘기면 Music은 그 곡을 바로 재생한다
        if action == .resume && (heldPause != nil || lastPlayerState == "Paused") {
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
                // 멈춘 뒤에는 새 소리가 나가지 않는다. 이미 장치로 넘어간 소리가 빠질 시간만 두고 음소거를 푼다
                // (준비 확인 스크립트의 확인 신호나 다른 앱 소리는 막지 않는다)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.unmuteAfterSwitch() }
                // 일시정지를 확인하는 사이에 이 전환이 취소됐다 (releaseHold): 방금 멈춘 곡을 다시 재생
                guard generation == self.switchGeneration || self.switchInFlight else {
                    let state = MusicScripting.PauseState(persistentID: result.state.persistentID, action: self.resumeAction)
                    DispatchQueue.global(qos: .userInteractive).async {
                        let detail = MusicScripting.resume(state)
                        DispatchQueue.main.async { self.onMessage?(.detail(detail)) }
                    }
                    return
                }
                // 더 새로운 전환이 이미 붙잡아 둔 상태를, 늦게 돌아온 이전 일시정지 결과로 덮어쓰지 않는다
                if self.heldPause == nil || generation == self.switchGeneration {
                    if self.heldPause == nil { self.resumedByOtherDuringHold = false }
                    self.heldPause = result.state
                }
                proceed()
            }
        }
        // 일시정지 명령을 먼저 보내 두고, 그동안 음소거한다 (장치 element마다 몇 ms씩 걸려 일시정지를 늦추지 않게)
        muteForSwitch(device)
    }

    /// 진행 중인 전환의 기다림에 합류: 다시 일시정지만 하고, 재개는 그 전환이 끝날 때 한다.
    private func holdAgain(then action: MusicScripting.ResumeAction) {
        let generation = switchGeneration
        let started = Date()
        resumeAction = action
        DispatchQueue.global(qos: .userInteractive).async {
            let result = MusicScripting.pauseNow(then: action)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                self.onMessage?(result.paused
                    ? .info(L("Paused in %ldms (%ld tries)", ms, result.attempts))
                    : .warning(L("Couldn’t confirm pause in %ldms (%ld tries)", ms, result.attempts)))
                guard self.switchInFlight, generation == self.switchGeneration else {
                    // 일시정지가 확인되기 전에 기다림이 끝나 이미 재개했다: 방금 멈춘 곡을 다시 재생
                    DispatchQueue.global(qos: .userInteractive).async { MusicScripting.resume(result.state) }
                    return
                }
                self.heldPause = result.state
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
                // 장치 확인 알림이 없었어도 스크립트가 준비를 확인했다
                pendingOutcome = .ready
                onMessage?(.info(L("Ready script finished in %ldms", Int(elapsed * 1000))))
                resumeHeld(generation: generation)
            case .failed(let reason):
                lastReadyScriptFailure = reason
                pendingOutcome = .uncertain(L("Ready script failed: %@", reason))
                let remaining = max(fallbackDelay - elapsed, 0)
                if remaining == 0 {
                    onMessage?(.warning(L("Ready script failed (%@), resuming now", reason)))
                    resumeHeld(generation: generation)
                } else {
                    onMessage?(.warning(L("Ready script failed (%@), resuming after %ldms", reason, Int(remaining * 1000))))
                    phase = .settling(to: rate, until: Date().addingTimeInterval(remaining))
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { self.resumeHeld(generation: generation) }
                }
            }
        }
    }

    /// 전환할 필요가 없어졌을 때: 붙잡아 둔 일시정지가 있으면 재개
    private func muteForSwitch(_ device: AudioDevice) {
        guard mutedForSwitch == nil else { return }
        let started = Date()
        // 사용자가 이미 음소거해 둔 element는 건드리지 않는다 (풀 때도 그대로 두도록)
        let elements = device.mutableOutputElements.filter { !device.isOutputMuted(element: $0) }
        guard !elements.isEmpty else { return }
        elements.forEach { device.setOutputMuted(true, element: $0) }
        mutedForSwitch = (device, elements)
        // 음소거한 채로 앱이 끝나면 다음 실행 때 푼다
        UserDefaults.standard.set(["uid": device.uid, "elements": elements.map(Int.init)], forKey: Self.mutedForSwitchKey)
        onMessage?(.detail(L("Muted output (channels %@, %ldms)", elements.map { $0 == 0 ? L("all") : String($0) }.joined(separator: ","),
                             Int(Date().timeIntervalSince(started) * 1000))))
    }

    private func unmuteAfterSwitch() {
        guard let (device, elements) = mutedForSwitch else { return }
        mutedForSwitch = nil
        elements.forEach { device.setOutputMuted(false, element: $0) }
        UserDefaults.standard.removeObject(forKey: Self.mutedForSwitchKey)
        onMessage?(.detail(L("Unmuted output")))
    }

    /// 지난 실행이 음소거를 풀지 못하고 끝났으면 푼다
    private func restoreMuteLeftOver() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.mutedForSwitchKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.mutedForSwitchKey)
        guard let uid = saved["uid"] as? String, let elements = saved["elements"] as? [Int],
              let device = AudioDevice.all.first(where: { $0.uid == uid }) else { return }
        elements.forEach { device.setOutputMuted(false, element: UInt32($0)) }
    }

    private func releaseHold() {
        unmuteAfterSwitch()
        if heldPause != nil || switchInFlight { pendingOutcome = .cancelled }
        if heldPause != nil {
            switchGeneration += 1
            resumeHeld(generation: switchGeneration)
        } else if switchInFlight {
            // 일시정지를 확인하는 중이라 아직 rate를 보내기 전이다 (예: 바꾸려던 곡에서 원래 rate 곡으로 바로 돌아옴).
            // 그 전환을 취소하지 않으면 늦게 돌아온 일시정지 결과가 이어서 rate를 바꿔 버린다.
            // 취소된 전환의 일시정지 결과는 switchWithPause에서 다시 재생한다.
            switchGeneration += 1
            switchInFlight = false
            lastOutcome = pendingOutcome
            phase = .idle
            armUpcomingDeferredDuringSwitch()
        }
    }

    private func armUpcomingDeferredDuringSwitch() {
        guard let deferred = upcomingDuringSwitch else { return }
        upcomingDuringSwitch = nil
        // 그사이 그 곡이 이미 지금 곡이 됐으면 다음 곡이 아니다
        guard deferred.item != tracker.currentItem(of: deferred.player) else { return }
        upcomingPrepared(player: deferred.player, item: deferred.item, format: deferred.format)
    }

    private func resumeHeld(generation: Int) {
        guard generation == switchGeneration else { return }
        unmuteAfterSwitch()
        switchInFlight = false
        lastOutcome = pendingOutcome
        phase = .idle
        armUpcomingDeferredDuringSwitch()
        guard let held = heldPause else { return }
        heldPause = nil
        if resumedByOtherDuringHold {
            resumedByOtherDuringHold = false
            onMessage?(.info(L("Music is already playing, so not resuming")))
            return
        }
        let state = MusicScripting.PauseState(persistentID: held.persistentID, action: resumeAction)
        switch state.action {
        case .advance: onMessage?(.info(L("Resumed (next track)")))
        case .rewind: onMessage?(.info(L("Resumed (from the beginning)")))
        case .resume: onMessage?(.info(L("Resumed")))
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let detail = MusicScripting.resume(state)
            DispatchQueue.main.async { self.onMessage?(.detail(detail)) }
        }
    }

    // MARK: - 곡 전환 효과 (AutoMix·크로스페이드)

    private func handle(_ transition: MusicLog.Transition) {
        let before = transitionStart
        switch transition {
        case let .overlapStart(item, at):
            // 곡 전환 효과를 끄거나 취소하면 nan이 온다. 남겨 두면 겹치지도 않는데 곡 끝보다 일찍 멈춘다
            overlapStarts[item] = at
        case .began:
            onMessage?(.detail(L("Transition began")))
            inTransition = true
            transitionGeneration += 1
            let generation = transitionGeneration
            // 끝 로그를 놓쳐도 붙잡히지 않게 (AutoMix 전환은 최대 60초)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [self] in
                if generation == transitionGeneration { transitionEnded() }
            }
        case .ended:
            transitionEnded()
        }
        guard transitionStart != before else { return }
        if let start = transitionStart {
            onMessage?(.detail(L("Transition planned at %@", Self.clock(start))))
        } else {
            onMessage?(.detail(L("Transition cancelled")))
        }
        // 이미 잡아 둔 일시정지 시각을 새 계획에 맞춰 다시 정한다
        if upcoming != nil {
            endWatchGeneration += 1
            checkEnd(generation: endWatchGeneration)
        }
    }

    private func transitionEnded() {
        guard inTransition else { return }
        inTransition = false
        transitionGeneration += 1
        onMessage?(.detail(L("Transition ended")))
        guard let pending = afterTransition else { return }
        afterTransition = nil
        setRate(pending.rate, reason: pending.reason, then: .rewind)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "?" }
        return String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - 곡 끝 직전 일시정지

    /// 다음 곡의 rate가 지금과 다르면, 현재 곡이 끝나기 직전에 멈추도록 감시를 건다.
    /// 곡이 넘어간 뒤에 멈추면 새 곡 앞부분이 잠깐 새어 나가므로, 넘어가기 전에 멈추는 게 근본 해결.
    private func upcomingPrepared(player: String, item: String, format: MusicLogTracker.Format) {
        if replayingRecentLog {
            upcomingDuringReplay = (player, item, format)
            return
        }
        if switchInFlight {
            upcomingDuringSwitch = (player, item, format)
            return
        }
        guard settleDelay != nil, !dryRun else { return }
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
                // AutoMix·크로스페이드는 곡 끝보다 먼저 다음 곡을 겹치기 시작하므로, 그 전에 멈춰야 전환이 시작되지 않는다
                let overlaps = transitionStart.map { $0 > position && $0 < finish } ?? false
                let remaining = (overlaps ? transitionStart! : finish) - position
                let leadTime = overlaps ? max(preEndLead, transitionLead) : preEndLead
                if remaining > leadTime + 0.5 {
                    recheck(min(remaining - leadTime - 0.4, 5))
                    return
                }
                // 다음 곡을 너무 늦게 알게 돼 곡 끝까지 거의 안 남았으면, 실제 곡 전환 때 처리한다.
                // 보통은 곡을 넘긴 경우다: Music은 넘기는 순간에야 다음 곡을 불러오고, 그때 재생 위치를 곡 끝으로 알려 준다.
                // 곡이 실제로 끝날 때 늦게 안 경우와 로그로는 구분할 수 없어 둘 다 맞는 사실만 남긴다
                guard remaining >= 0.1 else {
                    disarmEndWatch()
                    onMessage?(.info(L("Learned the next track’s format as the track changed (e.g. skipped), switching when it changes")))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(remaining - leadTime, 0)) { [self] in
                    guard generation == endWatchGeneration, settleDelay != nil else { return }
                    disarmEndWatch()
                    let lead = Int(min(remaining, leadTime) * 1000)
                    onMessage?(.info(overlaps ? L("Pausing %ldms before the song transition", lead)
                                              : L("Pausing %ldms before the end", lead)))
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
            // 앱의 재개는 heldPause를 비운 뒤에 보내므로, 붙잡고 있는 동안 멈춰 둔 그 곡이 다시 Playing이면 다른 쪽이 재생한 것이다.
            // (다른 곡이면 곡을 넘긴 것이다: Music이 넘긴 곡을 바로 재생하고, 그 곡은 앱이 다시 멈추거나 새로 전환한다)
            // 곡이 바뀐 직후 멈출 때는 앱의 일시정지가 Music의 Playing 알림보다 먼저 확인되기도 하므로,
            // 잠시 뒤 실제로 재생 중인지 다시 확인한다
            // 알림에 곡 ID가 없을 때가 많아(Apple Music 곡) 같은 곡인지도 그때 Music에 묻는다
            if let self, note.userInfo?["Player State"] as? String == "Playing", let held = heldPause,
               held.persistentID != nil, !resumedByOtherDuringHold {
                let generation = switchGeneration
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    guard MusicEvents.playerState == .playing,
                          MusicEvents.currentTrackPersistentID == held.persistentID else { return }
                    DispatchQueue.main.async {
                        guard generation == self.switchGeneration, self.heldPause != nil, !self.resumedByOtherDuringHold else { return }
                        self.resumedByOtherDuringHold = true
                        self.onMessage?(.warning(L("Music started playing during the switch (Music window, keyboard, or another app). The sample rate may not match until the next track.")))
                    }
                }
            }
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
            // 이 스레드는 앱이 끝날 때까지 돌므로, 읽을 때마다 자동 해제 풀을 비워야 한다.
            // 그러지 않으면 availableData가 돌려준 조각(약 16KB)과 그 사이 만든 문자열이 해제되지 않고 계속 쌓인다.
            var ended = false
            while !ended {
                autoreleasepool {
                    let chunk = handle.availableData
                    if chunk.isEmpty { ended = true; return }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        guard let line = String(data: lineData, encoding: .utf8),
                              let entry = MusicLog.parse(ndjsonLine: line) else { continue }
                        DispatchQueue.main.async { self?.receive(liveMessage: entry.message) }
                    }
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

    private func receive(liveMessage message: String) {
        if replayingRecentLog {
            liveDuringReplay.append(message)
        } else {
            feed(logMessage: message)
        }
    }

    // MARK: - 켤 때 지난 로그 다시 읽기

    /// Music은 곡의 포맷을 오디오를 만들 때(곡 시작·다음 곡 미리 불러오기) 한 번만 로그로 남긴다.
    /// 재생 도중에 앱을 켜면(업데이트 후 재실행 등) 지금 곡과 이미 불러온 다음 곡의 포맷을 영영 모르게 되어,
    /// 다음 곡으로 넘어가도 rate를 바꾸지 못한다. 그래서 지금 곡이 시작된 무렵부터의 로그를 다시 읽어 상태를 되살린다.
    /// 다시 읽는 동안은 장치를 건드리지 않고(지나간 판단이므로), 다 읽은 뒤 지금 곡의 rate만 맞춘다.
    private func replayRecentLog() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 곡 시작 로그가 들어가도록 재생 위치보다 넉넉히. 너무 길면 읽는 데 오래 걸린다 (30분 ≈ 5초)
            let position = MusicEvents.playerPosition
            let paused = MusicEvents.playerState == .paused
            let finish = MusicEvents.currentTrackFinish
            let seconds = Int(min(max((position ?? 600) + 120, 300), 1800))
            let messages = Self.readRecentLog(seconds: seconds)
            DispatchQueue.main.async { [self] in
                let (current, transitionInProgress) = applyReplay(messages)
                replayingRecentLog = false
                let live = liveDuringReplay
                liveDuringReplay = []
                onMessage?(.detail(L("Read %ld lines of Music’s log from the last %ld seconds", messages.count, seconds)))
                let next = upcomingDuringReplay
                upcomingDuringReplay = nil
                if let current {
                    onMessage?(.detail(L("Format     P/%@ %@ = %@", current.player, current.item, current.format.description)))
                }
                // 곡 끝(또는 곡 전환 효과) 직전에 멈춘 채 앱이 꺼졌다 (그 전환 도중에 업데이트·재실행 등).
                // 지금 곡 rate로 되돌려 재생하면 곧바로 다음 곡으로 넘어가거나 전환 효과가 시작되므로, 끝내지 못한 그 전환을 마친다
                var finishedPendingAdvance = false
                // (다음 곡 rate가 지금 곡과 다를 때만: 같으면 앱이 멈출 일이 없으니 사용자가 멈춰 둔 것이다)
                if paused, let next, let position, let current, next.format.sampleRate != current.format.sampleRate,
                   next.item != tracker.currentItem(of: next.player),
                   let boundary = transitionStart.flatMap({ $0 > position ? $0 : nil }) ?? finish, boundary - position < 1 {
                    finishedPendingAdvance = true
                    onMessage?(.info(L("Music was paused just before the next track, switching for it")))
                    if AudioDevice.defaultOutput?.nominalSampleRate == next.format.sampleRate {
                        // 꺼지기 전에 rate는 이미 바꿔 뒀다: 다음 곡으로 넘기기만 한다
                        DispatchQueue.global(qos: .userInteractive).async {
                            let state = MusicScripting.PauseState(persistentID: MusicEvents.currentTrackPersistentID, action: .advance)
                            let detail = MusicScripting.resume(state)
                            DispatchQueue.main.async { self.onMessage?(.detail(detail)) }
                        }
                    } else {
                        setRate(next.format.sampleRate, reason: "P/\(next.player) \(next.item) \(next.format.codec)", then: .advance)
                    }
                } else if let current, AudioDevice.defaultOutput?.nominalSampleRate != current.format.sampleRate, transitionInProgress {
                    // 곡 전환 효과가 진행 중이다: 지금 멈추면 Music이 전환을 취소하고 떠나던 곡으로 되돌리므로 끝난 뒤 바꾼다
                    handle(.began)
                    afterTransition = (current.format.sampleRate, "P/\(current.player) \(current.item) \(current.format.codec)")
                    onMessage?(.info(L("Song transition in progress, switching after it ends")))
                } else if let current, AudioDevice.defaultOutput?.nominalSampleRate != current.format.sampleRate {
                    // 앱을 켰을 때 이미 재생 중이던 곡: 곡 중간일 수 있으니 멈춘 자리에서 재개 (로컬 파일과 같다)
                    setRate(current.format.sampleRate, reason: "P/\(current.player) \(current.item) \(current.format.codec)", then: .resume)
                }
                if !finishedPendingAdvance, let next, next.item != tracker.currentItem(of: next.player) {
                    // 전환 중이면 끝난 뒤 바뀐 장치 rate로 판단한다
                    upcomingPrepared(player: next.player, item: next.item, format: next.format)
                }
                // 다시 읽은 구간과 겹칠 수 있지만, 같은 로그를 두 번 받아도 상태는 그대로다
                live.forEach(feed(logMessage:))
            }
        }
    }

    /// 지난 로그로 상태만 되살리고, 지금 곡의 포맷을 알면 돌려준다
    /// 지난 로그로 상태만 되살린다. 지금 곡의 포맷을 알면 돌려주고, 곡 전환 효과가 아직 진행 중인지도 알려 준다
    private func applyReplay(_ entries: [MusicLog.Entry])
        -> (current: (player: String, item: String, format: MusicLogTracker.Format)?, inTransition: Bool) {
        let messageHandler = onMessage
        onMessage = nil  // 지나간 일을 지금 일처럼 기록하지 않는다
        defer { onMessage = messageHandler }
        var current: (player: String, item: String, format: MusicLogTracker.Format)?
        var transitionBegan: Date??  // 시작했고 아직 끝나지 않은 전환 (시각을 못 읽으면 .some(nil))
        for entry in entries {
            let message = entry.message
            if let transition = MusicLog.transition(message) {
                // 전환의 시작·끝은 지금 진행 중인지만 따지고, 겹치기 계획은 되살린다
                switch transition {
                case .began: transitionBegan = .some(Self.logTimestamp.date(from: entry.timestamp))
                case .ended: transitionBegan = nil
                default: handle(transition)
                }
                continue
            }
            let before = tracker.currentItems
            switch tracker.handle(message) {
            case let .switchTo(p, i, f), let .formatChanged(p, i, f):
                current = (p, i, f)
            case nil:
                // 포맷을 모르는 곡으로 넘어갔으면 앞 곡의 포맷은 더 이상 지금 곡의 것이 아니다
                if tracker.currentItems != before { current = nil }
            }
        }
        // 끝 로그를 놓친 오래된 전환은 진행 중으로 보지 않는다 (AutoMix 전환은 최대 60초)
        let inTransition = transitionBegan.map { began in began.map { Date().timeIntervalSince($0) < 70 } ?? true } ?? false
        return (current, inTransition)
    }

    /// log show --style ndjson의 시각: 2026-11-08 13:14:39.151234+0900
    private static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    private static func readRecentLog(seconds: Int) -> [MusicLog.Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "\(seconds)s", "--style", "ndjson", "--predicate", MusicLog.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { MusicLog.parse(ndjsonLine: String($0)) }
    }
}
