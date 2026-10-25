import Foundation

/// 로컬 파일 곡은 coremedia 로그가 없고 AppleScript `sample rate`가 정확하다.
/// (스트리밍 곡은 class가 shared track이고 sample rate 값이 틀리므로 로그 쪽에서 처리한다)
public enum MusicScripting {
    public struct CurrentTrack {
        public let persistentID: String
        public let trackClass: String
        public let sampleRate: Double
        public let localPath: String?

        /// 보관함의 로컬 파일. 다운로드한 Apple Music 곡(.movpkg)도 file track이지만 스트리밍과 같은 경로라 제외
        public var isLocalFile: Bool {
            guard trackClass == "file track", let localPath else { return false }
            return !localPath.hasSuffix(".movpkg") && !localPath.hasSuffix(".movpkg/")
        }
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
        guard let text = run(script, cache: true) else { return nil }
        let parts = text.components(separatedBy: "\t")
        guard parts.count == 4 else { return nil }
        return CurrentTrack(persistentID: parts[0], trackClass: parts[1],
                            sampleRate: Double(parts[2]) ?? 0, localPath: parts[3].isEmpty ? nil : parts[3])
    }

    // MARK: - rate 전환 중 일시정지 (Apple Event 직접 전송, 수 ms)

    /// 재개할 때 할 일. 재생 위치로 추측하지 않고 왜 멈췄는지로 정한다.
    public enum ResumeAction {
        case resume   // 멈춘 자리에서 (곡 중간에 자동 전환을 다시 켰을 때 등)
        case rewind   // 곡 처음부터 (곡이 바뀐 직후 멈췄을 때: 감지 지연 동안 잘못 나간 앞부분 복구)
        case advance  // 다음 곡으로 (곡 끝 직전에 멈췄을 때)
    }

    public struct PauseState {
        public let persistentID: String?
        public let action: ResumeAction
    }

    /// 바로 일시정지를 보내고(응답 기다리지 않음), 실제로 멈출 때까지 확인한 뒤 멈춘 곡의 ID를 읽는다.
    /// 곡이 막 재생을 시작하려는 순간에 보낸 일시정지는 Music이 무시하고 재생을 이어 가는 경우가 있어서
    /// 멈춘 게 확인될 때까지 다시 보낸다 (최대 약 1초). 재생 중인지는 호출하는 쪽이 playerInfo 알림으로 판단한다.
    public static func pauseNow(then action: ResumeAction) -> (state: PauseState, attempts: Int, paused: Bool) {
        MusicEvents.pauseWithoutWaiting()
        var attempts = 1
        var paused = false
        for _ in 0..<20 {
            if MusicEvents.playerState == .paused {
                paused = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
            MusicEvents.pauseWithoutWaiting()
            attempts += 1
        }
        return (PauseState(persistentID: MusicEvents.currentTrackPersistentID, action: action), attempts, paused)
    }

    /// 다시 재생한다. rewind는 지금 곡을 처음으로 되돌린다 (곡이 막 바뀌었다는 판단이라, 붙잡는 동안 다른 곡으로
    /// 넘어갔어도 그 곡을 처음부터 듣는 게 맞다). advance는 멈췄던 곡이 그대로일 때만 넘긴다 (두 번 넘기지 않게).
    /// 진단용으로 무엇을 했는지 돌려준다.
    @discardableResult
    public static func resume(_ state: PauseState) -> String {
        let currentID = MusicEvents.currentTrackPersistentID
        let position = MusicEvents.playerPosition
        var did = "play"
        switch state.action {
        case .advance:
            if let id = state.persistentID, currentID == id { MusicEvents.nextTrack(); did = "next+play" }
        case .rewind:
            MusicEvents.setPlayerPosition(0); did = "rewind+play"
        case .resume:
            break
        }
        MusicEvents.play()
        return "paused id=\(state.persistentID ?? "nil") now id=\(currentID ?? "nil") pos=\(position.map { String(format: "%.2f", $0) } ?? "nil") → \(did)"
    }

    /// Music과의 Apple Event 연결을 미리 열어 둔다. 첫 호출은 100ms 넘게 걸려서 실제 전환 때 겪지 않게 한다.
    /// Music이 꺼져 있으면 띄우지 않는다.
    public static func warmUp() {
        _ = MusicEvents.playerState
        run(cache: true, """
        if application "Music" is running then
            tell application "Music" to get player state
        end if
        """)
    }

    // osascript 프로세스를 띄우면 호출마다 150ms 이상 걸린다. 앱 안에서 컴파일해 둔 NSAppleScript는 수 ms.
    // NSAppleScript는 스레드 안전하지 않아 전용 직렬 큐에서만 실행한다.
    private static let queue = DispatchQueue(label: "MusicScripting")
    private static var compiled: [String: NSAppleScript] = [:]  // queue에서만 접근

    @discardableResult
    private static func run(_ source: String, cache: Bool = false) -> String? {
        queue.sync {
            let script: NSAppleScript
            if cache, let cached = compiled[source] {
                script = cached
            } else {
                guard let fresh = NSAppleScript(source: source) else { return nil }
                var compileError: NSDictionary?
                guard fresh.compileAndReturnError(&compileError) else { return nil }
                if cache { compiled[source] = fresh }
                script = fresh
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil else { return nil }
            return (result.stringValue ?? "").trimmingCharacters(in: .newlines)
        }
    }

    @discardableResult
    private static func run(cache: Bool, _ source: String) -> String? {
        run(source, cache: cache)
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
