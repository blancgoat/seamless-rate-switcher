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
    }

    public enum Event: Equatable {
        case formatLearned(player: String, item: String, format: Format)
        case currentItemChanged(player: String, from: String?, to: String?)
        case waitingForFormat(player: String, item: String)
    }

    public var onEvent: ((Event) -> Void)?

    private var lastItemLogged: [String: String] = [:]   // player → 직전 로그의 item
    private var formats: [String: Format] = [:]          // "player|item" → format
    private var currentItem: [String: String] = [:]      // player → 현재 재생 item
    private var pending: [String: String] = [:]          // player → 포맷을 기다리는 현재 item
    private var audioPlayers = Set<String>()             // AudioQueue를 만든 적 있는 플레이어 (나머지는 아트워크 영상 등)

    public init() {}

    // [0x74c05bf400|P/WX] <0x74b0940000|I/LUM.01>
    private static let itemLog = try! NSRegularExpression(pattern: #"\|P/(\w+)\] <0x[0-9a-f]+\|(I/[\w.]+)>"#)
    // RP/WX.26 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:44100
    private static let audioQueue = try! NSRegularExpression(pattern: #"RP/(\w+)\.\d+ Creating AudioQueue with format:'([^']+)'.*?sampleRate:(\d+(?:\.\d+)?)"#)
    // <P/WX|0x74b58ab380> currentItem KVO: updating current item from I/LUM.01 to I/XKF.01
    private static let currentItemChange = try! NSRegularExpression(pattern: #"<P/(\w+)\|0x[0-9a-f]+> currentItem KVO: updating current item from (\S+) to (\S+)"#)

    /// coremedia 로그 메시지 한 줄. 장치 rate를 바꿔야 하면 Decision을 돌려준다.
    public func handle(_ message: String) -> Decision? {
        if let m = Self.match(Self.audioQueue, message) {
            let player = m[0]
            guard let item = lastItemLogged[player], let rate = Double(m[2]) else { return nil }
            let format = Format(codec: m[1], sampleRate: rate)
            audioPlayers.insert(player)
            if formats["\(player)|\(item)"] != format {
                formats["\(player)|\(item)"] = format
                onEvent?(.formatLearned(player: player, item: item, format: format))
            }
            if pending[player] == item {
                pending[player] = nil
                return .switchTo(player: player, item: item, format: format)
            }
            return nil
        }

        if let m = Self.match(Self.currentItemChange, message) {
            let player = m[0]
            let from = m[1] == "(null)" ? nil : m[1]
            let to = m[2] == "(null)" ? nil : m[2]
            // AVPlayer가 같은 전환을 여러 번 찍는 경우가 있어 중복은 무시
            guard currentItem[player] != to else { return nil }
            currentItem[player] = to
            pending[player] = nil
            // 로컬 파일 곡은 item 로그 없이 AudioQueue 로그만 찍힌다. 이전 곡 ID가 남아 있으면 그 곡 포맷을 덮어쓰므로 지운다.
            // (스트리밍 곡은 AudioQueue 직전에 항상 item 로그가 새로 찍힌다)
            lastItemLogged[player] = nil
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

        if let m = Self.match(Self.itemLog, message) {
            lastItemLogged[m[0]] = m[1]
        }
        return nil
    }

    private static func match(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let r = regex.firstMatch(in: s, range: range) else { return nil }
        return (1..<r.numberOfRanges).map { String(s[Range(r.range(at: $0), in: s)!]) }
    }
}

public enum MusicLog {
    /// log stream 필터. 위 세 종류 로그만 받는다 (전부 Default 레벨이라 --debug 불필요).
    public static let predicate = #"process == "Music" AND subsystem == "com.apple.coremedia" AND (eventMessage CONTAINS "Creating AudioQueue" OR eventMessage CONTAINS "updating current item" OR eventMessage CONTAINS "|P/")"#

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
