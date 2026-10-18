import CoreAudio
import Foundation

// Seamless Rate Switcher의 "준비 확인 스크립트": MOTU UltraLite mk5 (MOTU Gen 5 드라이버).
//
// MOTU 장치의 제어 채널은 MOTUWebSocketProxy가 USB를 독점하고 있어서,
// CueMix 5와 같은 방식으로 로컬 프록시(ws://127.0.0.1:1281/<시리얼>)에 접속해 장치 속성을 읽는다.
// id 22는 출력 준비 상태로 보인다 (CueMix 정의에 없는 속성, 실측으로 찾음): 샘플레이트 변경을 시작하면 0,
// FPGA/PLL 잠김(id 15/16) 약 3초 뒤 1. 평소엔 1로 남아 있을 때도, 잠깐만 1로 깜빡이고 0으로 돌아갈 때도 있었다.
// 앱은 장치가 변경을 알리기(약 1.4초)보다 먼저(약 0.6초) 이 스크립트를 실행하므로,
// 접속 시점의 값은 이전 상태일 수 있다. 그래서 "새 샘플레이트 + 접속 뒤 id 22가 0이 됐다가 다시 1"을 기다린다.
//
// CueMix 5의 비밀번호(원격 제어 비밀번호)가 꺼져 있을 때만 동작한다.
// 켜져 있으면 프록시가 인증을 요구하므로 종료 코드 3으로 끝난다.
//
// 사용:
//   motu-ultralite-mk5 [시리얼]          새 샘플레이트로 출력 준비가 끝나면 exit 0 (앱이 샘플레이트를 바꾼 뒤 실행)
//   motu-ultralite-mk5 watch [시리얼]    샘플레이트 변경 전후의 잠김·준비 신호 시점을 계속 출력
//
// 시리얼을 생략하면 앱이 넘겨주는 SRS_DEVICE_UID(예: com_motu_driver_gen5_control_interface:ul5xxxxxxx)에서 얻고,
// 그것도 없으면(터미널에서 직접 실행) 연결된 MOTU Gen 5 장치를 찾는다.
// 종료 코드: 0 준비됨, 1 접속/프로토콜 오류, 2 장치 없음, 3 비밀번호가 켜져 있음, 4 시간 초과

enum Prop {
    static let sampleRate = 10
    static let fpgaLocked = 15
    static let pllLocked = 16
    static let measuredRate = 17   // 문서 없음: 잠김 약 1초 뒤 실제 샘플레이트 값이 들어옴
    static let clockValid = 18     // 문서 없음: 잠김 직후 1
    static let outputReady = 22    // 문서 없음: 변경 시작 시 0, 잠김 약 3초 뒤 1 → DAC 출력 재개로 보임
    static let names = [sampleRate: "SampleRate", fpgaLocked: "FPGALocked", pllLocked: "PLLLocked",
                        measuredRate: "id17", clockValid: "id18", outputReady: "id22(ready)"]
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write("motu-ultralite-mk5: \(message)\n".data(using: .utf8)!)
    exit(code)
}

func info(_ message: String) {
    FileHandle.standardError.write("motu-ultralite-mk5: \(message)\n".data(using: .utf8)!)
}

// MARK: - 인자

var args = Array(CommandLine.arguments.dropFirst())
let command: String
if let first = args.first, first == "watch" {
    command = first
    args.removeFirst()
} else {
    command = "wait"
}
var timeout: TimeInterval = 20
if let i = args.firstIndex(of: "--timeout"), args.indices.contains(i + 1), let t = Double(args[i + 1]) {
    timeout = t
    args.removeSubrange(i...(i + 1))
}

/// "com_motu_driver_gen5_control_interface:ul5xxxxxxx" → "UL5XXXXXXX"
func serial(fromUID uid: String) -> String? {
    guard uid.hasPrefix("com_motu_driver_gen5"), let tail = uid.split(separator: ":").last else { return nil }
    return tail.uppercased()
}

/// 연결된 Core Audio 장치 중 MOTU Gen 5 장치의 UID들
func connectedMOTUSerials() -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return serial(fromUID: uid.takeRetainedValue() as String)
    }
}

/// 시리얼: 인자 → 앱이 넘긴 SRS_DEVICE_UID → 연결된 MOTU 장치 (하나일 때) 순서로 찾는다
let serial: String = {
    if let explicit = args.first { return explicit.uppercased() }
    if let uid = ProcessInfo.processInfo.environment["SRS_DEVICE_UID"] {
        guard let found = serial(fromUID: uid) else { fail(2, "MOTU Gen 5 장치가 아닙니다: \(uid)") }
        return found
    }
    let connected = Array(Set(connectedMOTUSerials())).sorted()
    switch connected.count {
    case 1: return connected[0]
    case 0: fail(2, "연결된 MOTU Gen 5 장치를 찾지 못했습니다.")
    default: fail(2, "MOTU 장치가 여러 대입니다. 시리얼을 지정하세요: \(connected.joined(separator: ", "))")
    }
}()

// MARK: - 프록시 프로토콜 (CueMix 5의 datastore.js와 같은 메시지 형식)

final class ProxyClient {
    var onProperty: ((Int, [UInt8]) -> Void)?
    var onConnected: (() -> Void)?

    private let task: URLSessionWebSocketTask
    private var connected = false

    init(serial: String) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:1281/\(serial)")!)
    }

    func start() {
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [self] result in
            switch result {
            case .failure(let error): fail(1, "프록시 연결 끊김: \(error.localizedDescription)")
            case .success(.data(let data)): DispatchQueue.main.async { self.handle([UInt8](data)) }
            case .success: break
            }
            receive()
        }
    }

    /// 메시지 앞 2바이트가 속성 id (빅엔디언). 0xFFFE는 장치가 아닌 프록시 자체의 메시지.
    private func handle(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        let id = Int(bytes[0]) << 8 | Int(bytes[1])
        let body = Array(bytes.dropFirst(2))
        if id == 0xFFFE {
            // 0x0000 = 인증 요청: CueMix 비밀번호가 켜져 있다
            if body.count >= 2, body[0] == 0, body[1] == 0 {
                fail(3, "CueMix 5의 비밀번호가 켜져 있어 동작할 수 없습니다. CueMix에서 비밀번호를 끄세요.")
            }
            return
        }
        if !connected {
            connected = true
            onConnected?()
        }
        onProperty?(id, body)
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// 속성 값 바이트의 마지막 값(정수). 앞 2바이트는 길이/플래그로 보인다.
func value(_ bytes: [UInt8]) -> Int {
    bytes.dropFirst(2).reduce(0) { $0 << 8 | Int($1) }
}

// MARK: - 명령

switch command {
case "watch":
    let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    var changedAt: Date?
    let client = ProxyClient(serial: serial)
    client.onConnected = { print("연결됨. 샘플레이트를 바꾸면 시점을 출력합니다 (Ctrl-C로 종료).") }
    client.onProperty = { id, bytes in
        guard let name = Prop.names[id] else { return }
        let now = Date()
        if id == Prop.sampleRate { changedAt = now }
        let since = changedAt.map { String(format: "+%.2fs", now.timeIntervalSince($0)) } ?? ""
        print("\(clock.string(from: now))  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value(bytes))\t\(since)")
        fflush(stdout)
    }
    client.start()

default:
    let started = Date()
    // 앱이 넘겨준 새 샘플레이트 (터미널에서 직접 실행하면 없음 → 샘플레이트 조건 없이 id 22만 본다)
    let targetRate = ProcessInfo.processInfo.environment["SRS_SAMPLE_RATE"].flatMap(Int.init)
    var deviceRate: Int?
    var sawNotReady = false   // 접속 뒤 id 22가 0인 걸 봤는지 (접속 시점의 1은 이전 상태일 수 있다)
    let client = ProxyClient(serial: serial)
    client.onProperty = { id, bytes in
        switch id {
        case Prop.sampleRate:
            deviceRate = value(bytes)
        case Prop.outputReady:
            if value(bytes) == 0 { sawNotReady = true; return }
            let rateMatches = targetRate == nil || deviceRate == targetRate
            guard sawNotReady, rateMatches else { return }
            info(String(format: "준비 신호 수신 (%.2fs)", Date().timeIntervalSince(started)))
            exit(0)
        default:
            break
        }
    }
    client.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        fail(4, String(format: "%.0f초 안에 준비 신호가 오지 않았습니다", timeout))
    }
}

dispatchMain()
