import Foundation

/// 로컬 파일 곡은 coremedia 로그가 없고 AppleScript `sample rate`가 정확하다.
/// (스트리밍 곡은 class가 shared track이고 sample rate 값이 틀리므로 로그 쪽에서 처리한다)
public enum MusicScripting {
    public struct CurrentTrack {
        public let persistentID: String
        public let trackClass: String
        public let sampleRate: Double
        public let localPath: String?

        public var isLocalFile: Bool { trackClass == "file track" && localPath != nil }
    }

    private static let script = """
    tell application "Music"
        set t to current track
        set c to class of t as text
        set loc to ""
        if c is "file track" then
            try
                set loc to POSIX path of (location of t as alias)
            end try
        end if
        return (persistent ID of t) & tab & c & tab & (sample rate of t as text) & tab & loc
    end tell
    """

    /// 현재 곡 정보. 실패하면 nil (Music이 꺼져 있거나 자동화 권한 거부).
    public static func currentTrack() -> CurrentTrack? {
        guard let text = run(script) else { return nil }
        let parts = text.components(separatedBy: "\t")
        guard parts.count == 4 else { return nil }
        return CurrentTrack(persistentID: parts[0], trackClass: parts[1],
                            sampleRate: Double(parts[2]) ?? 0, localPath: parts[3].isEmpty ? nil : parts[3])
    }

    // MARK: - rate 전환 중 일시정지

    public struct PauseState {
        public let persistentID: String
        /// 일시정지한 시점의 곡 위치(초)
        public let position: Double
    }

    /// 재생 중이면 일시정지하고 그 상태를 돌려준다. 재생 중이 아니면 nil.
    public static func pauseIfPlaying() -> PauseState? {
        let text = run("""
        tell application "Music"
            if player state is not playing then return ""
            pause
            return (persistent ID of current track) & tab & (player position as text)
        end tell
        """)
        guard let parts = text?.components(separatedBy: "\t"), parts.count == 2 else { return nil }
        // 로케일에 따라 소수점이 쉼표로 올 수 있다
        let position = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        return PauseState(persistentID: parts[0], position: position)
    }

    /// 일시정지했던 곡이 그대로면 (필요하면 처음으로 되돌려서) 다시 재생한다.
    public static func resume(_ state: PauseState, rewind: Bool) {
        run("""
        tell application "Music"
            if persistent ID of current track is "\(state.persistentID)" then
                \(rewind ? "set player position to 0" : "")
                play
            end if
        end tell
        """)
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    /// playerInfo 알림의 PersistentID(부호 있는 정수)를 AppleScript 형식(16자리 hex)으로 바꾼다.
    public static func hexPersistentID(_ value: Any?) -> String? {
        guard let n = value as? NSNumber else { return nil }
        return String(format: "%016llX", UInt64(bitPattern: n.int64Value))
    }

    /// 곡 전환 직후에는 current track이 이전 곡을 돌려줄 때가 있어서, ID가 맞을 때까지 몇 번 다시 묻는다.
    public static func currentTrack(matching persistentID: String, attempts: Int = 6, interval: TimeInterval = 0.3) -> CurrentTrack? {
        for attempt in 0..<attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: interval) }
            if let track = currentTrack(), track.persistentID == persistentID { return track }
        }
        return nil
    }
}
