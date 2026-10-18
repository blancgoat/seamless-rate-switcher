import CoreAudio
import Foundation

// 출력: 한 줄에 JSON 하나 (ndjson). log stream 결과와 시각으로 맞춰보기 위해 로컬 타임존 + ms 단위.
let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = .current
    return f
}()

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var obj = fields
    obj["ts"] = iso.string(from: Date())
    obj["event"] = event
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

let useAppleScript = CommandLine.arguments.contains("--as")

// MARK: - Core Audio

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func float64Property(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64 {
    var addr = address(selector)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value)
    return value
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let name else { return "?" }
    return name.takeRetainedValue() as String
}

func deviceFields(_ dev: AudioObjectID) -> [String: Any] {
    [
        "device_id": dev,
        "device": deviceName(dev),
        "nominal_rate": float64Property(dev, kAudioDevicePropertyNominalSampleRate),
        "actual_rate": float64Property(dev, kAudioDevicePropertyActualSampleRate),
    ]
}

// 장치마다 한 번만 리스너 등록. 기본 출력 장치가 바뀌면 새 장치에도 건다.
var watchedDevices = Set<AudioObjectID>()

func watchDevice(_ dev: AudioObjectID) {
    guard dev != kAudioObjectUnknown, !watchedDevices.contains(dev) else { return }
    watchedDevices.insert(dev)
    for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyActualSampleRate] {
        var addr = address(selector)
        let label = selector == kAudioDevicePropertyNominalSampleRate ? "nominal_rate_changed" : "actual_rate_changed"
        AudioObjectAddPropertyListenerBlock(dev, &addr, .main) { _, _ in
            emit(label, deviceFields(dev))
        }
    }
}

var defaultAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { _, _ in
    let dev = defaultOutputDevice()
    watchDevice(dev)
    emit("default_output_changed", deviceFields(dev))
}

// MARK: - Music.app

func appleScriptTrackInfo() -> String? {
    let script = """
    tell application "Music" to get {name, sample rate, bit rate, kind} of current track
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

var lastPersistentID: String?

DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
) { note in
    var fields: [String: Any] = [:]
    for (key, value) in note.userInfo ?? [:] {
        let k = "\(key)"
        fields[k] = value is NSNumber ? value : "\(value)"
    }
    fields.merge(deviceFields(defaultOutputDevice())) { a, _ in a }
    emit("player_info", fields)

    // 곡 전환 때 Stopped → Playing 알림이 연달아 오므로, 곡 ID가 바뀐 Playing 알림에서만 조회
    let pid = note.userInfo?["PersistentID"].map { "\($0)" }
    guard note.userInfo?["Player State"] as? String == "Playing", let pid, pid != lastPersistentID else { return }
    lastPersistentID = pid

    if useAppleScript {
        // 곡 전환 직후 값과 조금 뒤 값이 다른지도 보기 위해 두 번 조회
        for delay in [0.0, 3.0] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                let info = appleScriptTrackInfo() ?? "nil"
                DispatchQueue.main.async { emit("applescript", ["delay": delay, "result": info]) }
            }
        }
    }
}

// MARK: - 수동 마커: Enter 치면 mark 이벤트 (예: "지금 44.1로 떨어짐"), q 입력 시 종료

DispatchQueue.global().async {
    while let line = readLine() {
        if line == "q" { DispatchQueue.main.async { emit("stop"); exit(0) } ; return }
        DispatchQueue.main.async { emit("mark", ["note": line]) }
    }
}

let initial = defaultOutputDevice()
watchDevice(initial)
emit("start", deviceFields(initial).merging(["applescript": useAppleScript]) { a, _ in a })
dispatchMain()
