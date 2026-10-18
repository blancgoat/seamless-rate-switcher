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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard parts.count == 4 else { return nil }
        return CurrentTrack(persistentID: parts[0], trackClass: parts[1],
                            sampleRate: Double(parts[2]) ?? 0, localPath: parts[3].isEmpty ? nil : parts[3])
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
