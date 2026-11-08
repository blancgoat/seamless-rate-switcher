import Foundation

/// Music.app의 coremedia 로그를 한 줄씩 받아 "지금 실제로 재생되는 곡의 포맷"을 판단한다.
///
/// 관찰한 사실 (docs/findings.md):
/// - `RP/WX.n Creating AudioQueue ... sampleRate:N` 로그에는 곡 ID가 없다. 다음 곡 prefetch, 일시정지, 시크 때도 찍힌다.
/// - 같은 플레이어의 직전 `[0x..|P/WX] <0x..|I/LUM.01>` 로그가 그 AudioQueue가 어느 곡 것인지 알려준다.
/// - 실제 곡 전환은 `<P/WX|0x..> currentItem KVO: updating current item from X to Y`로 찍힌다.
///
/// 그래서 AudioQueue 로그로는 곡 ID → 포맷 맵만 채우고, 장치 rate는 곡 전환 시점에만 결정한다.
public final class MusicLogTracker {
    public struct Format: Equatable, CustomStringConvertible {
        public let codec: String
        public let sampleRate: Double
        public var description: String { "\(codec) \(Int(sampleRate))" }
    }

    public enum Decision: Equatable {
        /// 곡이 바뀌었고 포맷을 안다 → 이 rate로 맞춘다
        case switchTo(player: String, item: String, format: Format)
        /// 재생 중인 곡의 rate가 바뀌었다 (곡은 그대로) → 이 rate로 다시 맞춘다
        case formatChanged(player: String, item: String, format: Format)
    }

    public enum Event: Equatable {
        case formatLearned(player: String, item: String, format: Format)
        case currentItemChanged(player: String, from: String?, to: String?)
        case waitingForFormat(player: String, item: String)
    }

    public var onEvent: ((Event) -> Void)?

    private var lastItemLogged: [String: String] = [:]   // player(하위 플레이어 포함, 예: WX.2) → 직전 로그의 item
    private var formats: [String: Format] = [:]          // "player|item" → format
    private var currentItem: [String: String] = [:]      // player → 현재 재생 item
    private var leftItem: [String: String] = [:]         // player → 방금 떠난 item (전환 직후 그 곡의 정리 로그는 무시)
    private var pending: [String: String] = [:]          // player → 포맷을 기다리는 현재 item
    private var audioPlayers = Set<String>()             // AudioQueue를 만든 적 있는 플레이어 (나머지는 아트워크 영상 등)
    private var queueFormats: [String: Format] = [:]     // AudioQueue(예: FH.21) → 만들 때의 포맷 (파일 재생기가 재사용할 때 씀)

    public init() {}

    public func currentItem(of player: String) -> String? { currentItem[player] }
    /// player → 현재 item 전체 (곡이 바뀌었는지 비교용)
    public var currentItems: [String: String] { currentItem }

    // AutoMix 중에는 플레이어 안에 겹치기용 하위 플레이어(P/WX.2)가 생겨서 곡이 그쪽에서 재생된다.
    // 하위 플레이어는 자기 item 로그와 AudioQueue(RP/WX.2.16)를 따로 남기므로, 직전 item은 하위 플레이어별로 따로 기억하고
    // 곡 전환·포맷은 바깥 플레이어(WX) 기준으로 묶는다.
    // [0x74c05bf400|P/WX] <0x74b0940000|I/LUM.01>, [0x7b5d978000|P/WX.2] <0x7b58af5c00|I/GOG.01>
    private static let itemLog = try! NSRegularExpression(pattern: #"\|P/(\w+(?:\.\d+)*)\] <0x[0-9a-f]+\|(I/[\w.]+)>"#)
    // 파일 재생기(FigFilePlayer: 다운로드·캐시된 곡 등)는 위 형식 대신 AudioQueue를 만들기 직전에 이 로그로 곡을 알린다.
    // 이걸 놓치면 직전 item(떠나는 스트리밍 곡)의 포맷으로 잘못 기록한다. 곡 전환 로그보다 먼저 온다.
    // fp_buildAudioRenderPipelineForTrack: [0x7ad5cf4000|P/FH] called for <0x7ad1d69e00|I/FPZ.01>
    private static let fileItemLog = try! NSRegularExpression(pattern: #"\|P/(\w+(?:\.\d+)*)\] called for <0x[0-9a-f]+\|(I/[\w.]+)>"#)
    // RP/WX.26 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:44100 (하위 플레이어: RP/WX.2.16)
    private static let audioQueue = try! NSRegularExpression(pattern: #"RP/((\w+(?:\.\d+)*)\.\d+) Creating AudioQueue with format:'([^']+)'.*?sampleRate:(\d+(?:\.\d+)?)"#)
    // 파일 재생기는 다음 곡이 같은 포맷이면 AudioQueue를 새로 만들지 않고 이전 곡의 것을 그대로 쓴다 (AudioQueue 로그 없음).
    // 대신 곡 전환 몇 초 전에 이 로그를 남기므로, 그 AudioQueue를 만들 때 기록한 포맷을 이 곡의 포맷으로 본다.
    // itemfig_createRenderTriplesForAudio: <0x7ad20d9400|I/NOR.01> reusing old audio pipeline 0x7ad96f57c0 RP/FH.21
    private static let reusedPipeline = try! NSRegularExpression(pattern: #"<0x[0-9a-f]+\|(I/[\w.]+)> reusing old audio pipeline 0x[0-9a-f]+ RP/((\w+(?:\.\d+)*)\.\d+)"#)
    // 스트리밍 재생기도 다음 곡이 같은 포맷이면 AudioQueue를 새로 만들지 않고 그대로 쓴다 (로그 없음).
    // 대신 곡이 재생을 시작할 때(곡 전환 로그 직전) 그 곡의 실제 포맷을 이 로그로 알린다. 파일 재생기의 같은 로그에는 SampleRate가 없다.
    // fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x7976309c00|P/WE]: <0x7969a70e00|I/IQP.01>: [AudioFormat qlac is  decodable] ... [SampleRate 44100] ...
    private static let playbackReport = try! NSRegularExpression(pattern: #"ReportAudioPlaybackThroughFigLog: .*?\|P/(\w+(?:\.\d+)*)\]: <0x[0-9a-f]+\|(I/[\w.]+)>: \[AudioFormat (\S+).*?\[SampleRate (\d+(?:\.\d+)?)\]"#)
    // <P/WX|0x74b58ab380> currentItem KVO: updating current item from I/LUM.01 to I/XKF.01
    private static let currentItemChange = try! NSRegularExpression(pattern: #"<P/(\w+)\|0x[0-9a-f]+> currentItem KVO: updating current item from (\S+) to (\S+)"#)

    /// coremedia 로그 메시지 한 줄. 장치 rate를 바꿔야 하면 Decision을 돌려준다.
    public func handle(_ message: String) -> Decision? {
        if let m = Self.match(Self.audioQueue, message) {
            let queue = m[0]
            let subPlayer = m[1]
            let player = Self.outerPlayer(subPlayer)
            // 보통은 바로 앞 item 로그가 어느 곡의 AudioQueue인지 알려 준다. 파일 재생기로 재생되는 곡
            // (로컬 파일, 다운로드·캐시된 Apple Music AAC 등)은 그 로그가 없으므로, 곡이 막 바뀌어
            // 포맷을 기다리는 중이면 지금 곡의 것으로 본다 (다음 곡 미리 불러오기는 지금 곡 포맷을 안 뒤에 일어난다)
            guard let rate = Double(m[3]) else { return nil }
            let format = Format(codec: m[2], sampleRate: rate)
            queueFormats[queue] = format
            guard let item = lastItemLogged[subPlayer] ?? pending[player] else { return nil }
            return learn(player: player, item: item, format: format)
        }

        if let m = Self.match(Self.reusedPipeline, message) {
            guard let format = queueFormats[m[1]] else { return nil }
            return learn(player: Self.outerPlayer(m[2]), item: m[0], format: format)
        }

        if let m = Self.match(Self.playbackReport, message), let rate = Double(m[3]) {
            let player = Self.outerPlayer(m[0])
            let item = m[1]
            let format = Format(codec: m[2], sampleRate: rate)
            let key = "\(player)|\(item)"
            // 이 로그는 재생을 시작할 때마다(일시정지 후 다시 재생할 때도) 찍히고, 무손실 곡도 처음 여는
            // 손실(AAC) 스트림 기준으로 알린다 (예: qlac 96000 곡인데 [Rendition Stereo] qaac 48000).
            // 이미 포맷을 아는 곡에 이걸 반영하면 48000으로 전환 → 일시정지 → qlac 96000으로 되돌림 → 재생 →
            // 다시 이 로그가 qaac 48000을 알림 … 으로 끝없이 반복된다. 그래서 포맷을 모르는 곡에만 쓴다.
            guard formats[key] == nil else { return nil }
            // 지금 곡(또는 포맷을 기다리는 곡)이면 AudioQueue 로그와 똑같이 다룬다
            if currentItem[player] == item || pending[player] == item {
                return learn(player: player, item: item, format: format)
            }
            // 곧 시작할 곡: 곡 전환 로그가 바로 뒤따르므로 기록만 해 둔다.
            // (다음 곡 미리 불러오기로 다루면 곡 끝 감시를 걸게 되는데, 이미 곡이 넘어가는 중이다)
            formats[key] = format
            return nil
        }

        if let m = Self.match(Self.currentItemChange, message) {
            let player = m[0]
            let from = m[1] == "(null)" ? nil : m[1]
            let to = m[2] == "(null)" ? nil : m[2]
            // AVPlayer가 같은 전환을 여러 번 찍는 경우가 있어 중복은 무시
            guard currentItem[player] != to else { return nil }
            currentItem[player] = to
            leftItem[player] = from
            pending[player] = nil
            // 로컬 파일 곡은 item 로그 없이 AudioQueue 로그만 찍힌다. 이전 곡 ID가 남아 있으면 그 곡 포맷을 덮어쓰므로 지운다.
            // (스트리밍 곡은 AudioQueue 직전에 항상 item 로그가 새로 찍힌다)
            lastItemLogged = lastItemLogged.filter { Self.outerPlayer($0.key) != player }
            let isAudio = audioPlayers.contains(player)
            if isAudio { onEvent?(.currentItemChanged(player: player, from: from, to: to)) }
            guard let to else { return nil }
            if let format = formats["\(player)|\(to)"] {
                return .switchTo(player: player, item: to, format: format)
            }
            // 처음 재생하는 곡은 전환 로그가 AudioQueue 로그보다 먼저 온다
            pending[player] = to
            if isAudio { onEvent?(.waitingForFormat(player: player, item: to)) }
            return nil
        }

        if let m = Self.match(Self.itemLog, message) ?? Self.match(Self.fileItemLog, message) {
            // 곡이 넘어간 직후에도 Music은 떠난 곡을 정리하는 로그를 남긴다. 이걸 직전 item으로 잡으면
            // 다음 AudioQueue(특히 item 로그가 없는 로컬 파일)의 포맷을 떠난 곡의 것으로 잘못 기록하고,
            // 지금 곡이 아니니 "다음 곡 미리 불러오기"로 착각할 수 있다.
            guard m[1] != leftItem[Self.outerPlayer(m[0])] else { return nil }
            lastItemLogged[m[0]] = m[1]
        }
        return nil
    }

    /// AudioQueue 로그나 파이프라인 재사용 로그로 어느 곡의 포맷인지 알았을 때
    private func learn(player: String, item: String, format: Format) -> Decision? {
        audioPlayers.insert(player)
        let previous = formats["\(player)|\(item)"]
        if previous != format {
            formats["\(player)|\(item)"] = format
            onEvent?(.formatLearned(player: player, item: item, format: format))
        }
        if pending[player] == item {
            pending[player] = nil
            return .switchTo(player: player, item: item, format: format)
        }
        // 재생 중인 곡의 포맷이 바뀌었다. Music은 Apple Music 무손실 곡을 손실(AAC) 스트림으로 먼저 시작했다가
        // 곧 무손실로 바꾸곤 한다 (예: qaac 48000 → 약 0.6초 뒤 qlac 96000)
        if currentItem[player] == item, let previous, previous.sampleRate != format.sampleRate {
            return .formatChanged(player: player, item: item, format: format)
        }
        return nil
    }

    /// "WX.2" → "WX"
    private static func outerPlayer(_ player: String) -> String {
        String(player.prefix { $0 != "." })
    }

    private static func match(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let r = regex.firstMatch(in: s, range: range) else { return nil }
        return (1..<r.numberOfRanges).map { String(s[Range(r.range(at: $0), in: s)!]) }
    }
}

public enum MusicLog {
    /// log stream 필터. 위 세 종류 로그와 곡 전환 효과(AutoMix·크로스페이드) 로그만 받는다 (전부 Default 레벨이라 --debug 불필요).
    public static let predicate = #"process == "Music" AND ((subsystem == "com.apple.coremedia" AND (eventMessage CONTAINS "Creating AudioQueue" OR eventMessage CONTAINS "updating current item" OR eventMessage CONTAINS "|P/" OR eventMessage CONTAINS "reusing old audio pipeline" OR eventMessage CONTAINS "set advanceTimeForOverlappedPlayback")) OR (subsystem == "com.apple.amp.mediaplaybackcore" AND (eventMessage CONTAINS "Enter state: OverlappedTransitionState" OR eventMessage CONTAINS "Exit state: OverlappedTransitionState" OR eventMessage CONTAINS "ITEM TRANSITION END")))"#

    /// 곡 전환 효과(곡 사이를 겹쳐 섞는 AutoMix·크로스페이드) 로그.
    /// - 전환 계획 (둘 다): `set advanceTimeForOverlappedPlayback = 191.542 for item <…|I/FOU.01>` — 그 곡의 겹치기 시작 위치.
    ///   다음 곡을 준비할 때 오고, 취소하거나 전환 방식을 끄면 같은 로그가 nan으로 온다. 다시 계획하면 새 값이 뒤따른다.
    /// - 전환 시작: `STATE MACHINE: Enter state: OverlappedTransitionState` 직후에 currentItem이 다음 곡으로 바뀐다.
    /// - 전환 끝: `Exit state: OverlappedTransitionState`, `ITEM TRANSITION END` (취소될 때도 남는다).
    public enum Transition: Equatable {
        /// 이 곡의 이 위치(초)에서 다음 곡과 겹치기 시작한다. nil이면 계획이 없어졌다(취소·설정 끔)
        case overlapStart(item: String, at: TimeInterval?)
        case began
        case ended
    }

    // AutoMix·크로스페이드 모두 겹치기 시작 위치를 곡마다 이렇게 정한다 (취소하면 nan). 마지막 값이 유효하다.
    // playeroverlap_setAdvanceTimeForOverlappedPlaybackInPlayerQueue: set advanceTimeForOverlappedPlayback = 191.542 for item <0x74e9b289a0|I/FOU.01>
    // 예전에는 AutoMix 계획 로그(Outgoing Start)·끝 위치·겹치는 길이를 따로 모아 계산했는데, 전환 방식을 바꾸는 순간
    // Music이 새 계획을 먼저 남기고 옛 계획을 지우는 로그를 뒤에 남겨 새 계획까지 지워 버렸다.
    private static let overlapStart = try! NSRegularExpression(pattern: #"set advanceTimeForOverlappedPlayback = (nan|\d+(?:\.\d+)?) for item <0x[0-9a-f]+\|(I/[\w.]+)>"#)

    public static func transition(_ message: String) -> Transition? {
        let range = NSRange(message.startIndex..., in: message)
        if let match = overlapStart.firstMatch(in: message, range: range),
           let value = Range(match.range(at: 1), in: message), let item = Range(match.range(at: 2), in: message) {
            // Double("nan")은 nil이 아니라 NaN이 되므로 직접 거른다 (NaN을 그대로 두면 시각으로 바꿀 때 앱이 죽는다)
            let at = Double(message[value]).flatMap { $0.isFinite ? $0 : nil }
            return .overlapStart(item: String(message[item]), at: at)
        }
        if message.contains("Enter state: OverlappedTransitionState") { return .began }
        if message.contains("Exit state: OverlappedTransitionState") || message.contains("ITEM TRANSITION END") { return .ended }
        return nil
    }

    public struct Entry {
        public let timestamp: String
        public let subsystem: String
        public let message: String
    }

    /// log stream ndjson 한 줄을 해석한다. 첫 줄 같은 안내 문구는 nil.
    public static func parse(ndjsonLine line: String) -> Entry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["eventMessage"] as? String else { return nil }
        return Entry(timestamp: obj["timestamp"] as? String ?? "",
                     subsystem: obj["subsystem"] as? String ?? "",
                     message: message)
    }
}
