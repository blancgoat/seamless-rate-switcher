import Foundation

/// Music에 Apple Event를 직접 보낸다. AppleScript를 거치지 않아 수 ms 안에 끝나고,
/// NSAppleScript 큐(로컬 파일 조회 등)에 줄 서지 않는다. 코드는 Music.app의 com.apple.Music.sdef 기준.
/// Music이 실행 중이 아니면 띄우지 않고 실패(nil)한다.
public enum MusicEvents {
    public enum PlayerState { case playing, paused, stopped, unknown }

    public static var playerState: PlayerState {
        switch fetch(property("pPlS"))?.enumCodeValue {
        case code("kPSP"): .playing
        case code("kPSp"): .paused
        case code("kPSS"): .stopped
        default: .unknown
        }
    }

    /// 현재 곡에서의 재생 위치(초)
    public static var playerPosition: Double? { fetch(property("pPos"))?.doubleValue }

    /// 현재 곡이 끝나는 시각(초). 곡의 "finish"(정지 시각) 값이라 앞뒤를 잘라 둔 곡도 맞다
    public static var currentTrackFinish: Double? { fetch(property("pStp", of: property("pTrk")))?.doubleValue }

    public static var currentTrackPersistentID: String? { fetch(property("pPIS", of: property("pTrk")))?.stringValue }

    @discardableResult public static func pause() -> Bool { send("hook", "Paus") != nil }

    /// 응답을 기다리지 않고 일시정지를 보낸다. 곡이 막 시작할 때는 Music이 바빠서 응답이 수백 ms 늦을 수 있다.
    public static func pauseWithoutWaiting() {
        send("hook", "Paus", waitForReply: false)
    }
    @discardableResult public static func play() -> Bool { send("hook", "Play") != nil }
    @discardableResult public static func nextTrack() -> Bool { send("hook", "Next") != nil }

    @discardableResult
    public static func setPlayerPosition(_ seconds: Double) -> Bool {
        send("core", "setd", direct: property("pPos"), params: [("data", NSAppleEventDescriptor(double: seconds))]) != nil
    }

    // MARK: - Apple Event 조립

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// `<property> of <container>` 객체 지정자. container가 null이면 application.
    private static func property(_ propertyCode: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(propertyCode)), forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    private static func fetch(_ spec: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        send("core", "getd", direct: spec)
    }

    /// 응답의 direct object (없으면 빈 descriptor). 실패하면 nil
    @discardableResult
    private static func send(_ eventClass: String, _ eventID: String,
                             direct: NSAppleEventDescriptor? = nil,
                             params: [(String, NSAppleEventDescriptor)] = [],
                             waitForReply: Bool = true) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music"),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        for (keyword, value) in params { event.setParam(value, forKeyword: code(keyword)) }
        guard waitForReply else {
            _ = try? event.sendEvent(options: [.noReply], timeout: 0)
            return nil
        }
        guard let reply = try? event.sendEvent(options: [.waitForReply], timeout: 2) else { return nil }
        if reply.paramDescriptor(forKeyword: keyErrorNumber) != nil { return nil }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? NSAppleEventDescriptor.null()
    }
}
