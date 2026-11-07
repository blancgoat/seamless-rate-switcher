import AudioToolbox
import CoreAudio
import Foundation

// Seamless Rate Switcher의 "준비 확인 스크립트": MOTU UltraLite mk5 (MOTU Gen 5 드라이버).
//
// MOTU 장치의 제어 채널은 MOTUWebSocketProxy가 USB를 독점하고 있어서,
// CueMix 5와 같은 방식으로 로컬 프록시(ws://127.0.0.1:1281/<시리얼>)에 접속해 장치 속성을 읽는다.
//
// MOTU는 "출력 준비 완료"를 알려 주는 속성이 없다 (샘플레이트 변경 중 바뀌는 속성은 샘플레이트·잠김·측정 rate뿐).
// 잠김(약 1.2초)이 끝나도 실제 출력은 샘플레이트 변경 후 약 5.4초가 지나야 열리고, 그 전에 보낸 소리는 버려진다
// (2026-11-07 측정: 44.1k↔48k↔96k 모든 방향에서 같음).
// 그래서 들리지 않는 신호(-90dBFS, 21.5~23kHz)를 내보내면서 출력 미터를 보다가, 미터에 신호가 잡히는 순간
// (= 실제로 소리가 나가기 시작한 순간) 끝낸다. 미터는 -90dB까지만 표시하므로(-91dB부터는 안 잡힘) -90dBFS를 쓴다.
// 예전에 기다리던 id 22는 출력 준비가 아니라 앞면 화면이 꺼진 상태였다 (화면 꺼짐 시간 3초 설정에서 우연히 맞았다).
//
// CueMix 5의 비밀번호(원격 제어 비밀번호)가 꺼져 있을 때만 동작한다.
// 켜져 있으면 프록시가 인증을 요구하므로 종료 코드 3으로 끝난다.
//
// 사용:
//   motu-ultralite-mk5 [시리얼]          새 샘플레이트로 실제 출력이 열리면 exit 0 (앱이 샘플레이트를 바꾼 뒤 실행)
//   motu-ultralite-mk5 watch [시리얼]    샘플레이트 변경 전후의 잠김 시점과 출력 미터에 소리가 잡히는 시점을 계속 출력
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
    static let meters = 6000       // 레벨 미터 (초당 약 20번). 값 = -dB × 2, 0xFF = 신호 없음
    static let names = [sampleRate: "SampleRate", fpgaLocked: "FPGALocked", pllLocked: "PLLLocked",
                        measuredRate: "id17", clockValid: "id18"]
}

/// 미터 메시지에서 메인 출력 L/R 자리 (앞 2바이트 포함 위치).
/// 확인 신호는 스테레오라 둘 다에 나온다. 다른 자리(디지털 출력 등)는 샘플레이트를 바꾸는 동안 이전 소리의 값이
/// 혼자 남아 있기도 해서(예: 바이트 48만 -42dB) 쓰지 않는다. 입력(마이크 등) 자리도 쓰지 않는다.
let mainOutputMeterBytes = [2, 3]

func outputHasSignal(_ meters: [UInt8]) -> Bool {
    mainOutputMeterBytes.allSatisfy { $0 < meters.count && meters[$0] != 0xFF }
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

// MARK: - 들리지 않는 확인 신호

/// 장치가 실제로 소리를 내보내기 시작했는지 미터로 보기 위해 아주 작은 고음을 계속 내보낸다.
/// -90dBFS(미터가 표시하는 가장 작은 크기), 44.1kHz에서는 21.5kHz(표현할 수 있는 한계 근처), 48kHz 이상은 23kHz.
/// 장치가 준비되기 전에는 버려지고, 준비된 뒤 미터를 보고 끌 때까지(약 50ms)만 실제로 나간다.
/// Music과 같은 macOS 기본 재생 경로(AudioQueue)로 내보낸다.
final class Probe {
    private var queue: AudioQueueRef?
    private var phase = 0.0
    private let step: Double
    private let amplitude = Float(pow(10, -90.0 / 20))

    init(deviceUID: String?, sampleRate: Double) {
        let frequency = sampleRate >= 48000 ? 23000.0 : 21500.0
        step = 2 * .pi * frequency / sampleRate
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let this = Unmanaged.passUnretained(self).toOpaque()
        guard AudioQueueNewOutput(&format, { user, queue, buffer in
            Unmanaged<Probe>.fromOpaque(user!).takeUnretainedValue().fill(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, this, nil, nil, 0, &queue) == noErr, let queue else {
            info("확인 신호를 만들지 못했습니다 (미터만 봅니다)")
            return
        }
        if let deviceUID {
            var uid = Unmanaged.passRetained(deviceUID as CFString)
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
            uid.release()
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(queue, 1024 * 8, &buffer) == noErr, let buffer else { continue }
            fill(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func fill(_ buffer: AudioQueueBufferRef) {
        let frames = Int(buffer.pointee.mAudioDataBytesCapacity) / 8
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        for f in 0..<frames {
            let v = amplitude * Float(sin(phase))
            phase += step
            if phase > 2 * .pi { phase -= 2 * .pi }
            samples[f * 2] = v
            samples[f * 2 + 1] = v
        }
        buffer.pointee.mAudioDataByteSize = UInt32(frames * 8)
    }

    func start() {
        if let queue { AudioQueueStart(queue, nil) }
    }

    func stop() {
        if let queue { AudioQueueStop(queue, true) }
    }
}

// MARK: - 명령

switch command {
case "watch":
    let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    var changedAt: Date?
    let client = ProxyClient(serial: serial)
    client.onConnected = { print("연결됨. 샘플레이트를 바꾸면 시점을 출력합니다 (Ctrl-C로 종료).") }
    var outputOn: Bool?
    client.onProperty = { id, bytes in
        let now = Date()
        if id == Prop.meters {
            let on = outputHasSignal(bytes)
            guard on != outputOn else { return }
            outputOn = on
            let since = changedAt.map { String(format: "+%.2fs", now.timeIntervalSince($0)) } ?? ""
            print("\(clock.string(from: now))  \("output".padding(toLength: 12, withPad: " ", startingAt: 0)) \(on ? "소리 있음" : "없음")\t\(since)")
            fflush(stdout)
            return
        }
        guard let name = Prop.names[id] else { return }
        if id == Prop.sampleRate { changedAt = now }
        let since = changedAt.map { String(format: "+%.2fs", now.timeIntervalSince($0)) } ?? ""
        print("\(clock.string(from: now))  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value(bytes))\t\(since)")
        fflush(stdout)
    }
    client.start()

default:
    let started = Date()
    // 앱이 넘겨준 새 샘플레이트 (터미널에서 직접 실행하면 없음 → 샘플레이트 조건 없이 미터만 본다)
    let targetRate = ProcessInfo.processInfo.environment["SRS_SAMPLE_RATE"].flatMap(Int.init)
    var deviceRate: Int?
    let probe = Probe(deviceUID: ProcessInfo.processInfo.environment["SRS_DEVICE_UID"],
                      sampleRate: Double(targetRate ?? 48000))
    probe.start()
    let client = ProxyClient(serial: serial)
    client.onProperty = { id, bytes in
        switch id {
        case Prop.sampleRate:
            deviceRate = value(bytes)
        case Prop.meters:
            let rateMatches = targetRate == nil || deviceRate == targetRate
            guard rateMatches, outputHasSignal(bytes) else { return }
            probe.stop()
            info(String(format: "출력 미터에 소리가 잡힘 (%.2fs)", Date().timeIntervalSince(started)))
            exit(0)
        default:
            break
        }
    }
    client.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        probe.stop()
        fail(4, String(format: "%.0f초 안에 출력 미터에 소리가 잡히지 않았습니다", timeout))
    }
}

dispatchMain()
