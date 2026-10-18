import CryptoKit
import Foundation
import Security

// Seamless Rate Switcher의 "준비 확인 스크립트": MOTU UltraLite mk5 (MOTU Gen 5 드라이버).
//
// MOTU 장치의 제어 채널은 MOTUWebSocketProxy가 USB를 독점하고 있어서,
// CueMix 5와 같은 방식으로 로컬 프록시(ws://127.0.0.1:1281/<시리얼>)에 접속해 장치 속성을 읽는다.
// 샘플레이트를 바꾸면 장치가 FPGA/PLL 잠김(id 15/16) 뒤 약 3초 후에 id 22를 잠깐 1로 올리는데,
// 이 시점이 DAC 출력이 다시 열리는 시점으로 보인다 (CueMix 정의에 없는 속성, 실측으로 찾음).
//
// 사용:
//   motu-ultralite-mk5 set-password [시리얼]   비밀번호를 입력받아 SHA-256 해시만 키체인에 저장하고 인증을 확인
//   motu-ultralite-mk5 watch [시리얼]          샘플레이트 변경 전후의 잠김·준비 신호 시점을 계속 출력
//   motu-ultralite-mk5 [시리얼]                준비 신호(id 22)가 오면 exit 0 (앱이 샘플레이트를 바꾼 뒤 실행)
//
// 시리얼을 생략하면 앱이 넘겨주는 SRS_DEVICE_UID(예: com_motu_driver_gen5_control_interface:ul5eff6f7a)에서 얻는다.
// 종료 코드: 0 준비됨, 1 접속/프로토콜 오류, 2 시리얼·비밀번호 없음, 3 인증 실패, 4 시간 초과

enum Prop {
    static let sampleRate = 10
    static let fpgaLocked = 15
    static let pllLocked = 16
    static let measuredRate = 17   // 문서 없음: 잠김 약 1초 뒤 실제 샘플레이트 값이 들어옴
    static let clockValid = 18     // 문서 없음: 잠김 직후 1
    static let outputReady = 22    // 문서 없음: 잠김 약 3초 뒤 잠깐 1 → DAC 출력 재개로 보임
    static let names = [sampleRate: "SampleRate", fpgaLocked: "FPGALocked", pllLocked: "PLLLocked",
                        measuredRate: "id17", clockValid: "id18", outputReady: "id22(ready)"]
}

let keychainService = "dev.blancgoat.SeamlessRateSwitcher.motu-ultralite-mk5"

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
if let first = args.first, ["set-password", "watch"].contains(first) {
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

/// "com_motu_driver_gen5_control_interface:ul5eff6f7a" → "UL5EFF6F7A"
let serial: String = {
    if let explicit = args.first { return explicit.uppercased() }
    if let uid = ProcessInfo.processInfo.environment["SRS_DEVICE_UID"], uid.contains("motu"),
       let tail = uid.split(separator: ":").last {
        return tail.uppercased()
    }
    fail(2, "시리얼을 알 수 없습니다. motu-ultralite-mk5 [시리얼] 또는 SRS_DEVICE_UID 환경 변수가 필요합니다.")
}()

// MARK: - 키체인 (비밀번호 원문 대신 CueMix와 같은 SHA-256 16진수 해시만 저장)

func storedHash() -> String? {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
                                  kSecAttrAccount: serial, kSecReturnData: true]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func storeHash(_ hash: String) {
    let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: serial]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData] = Data(hash.utf8)
    add[kSecAttrLabel] = "Seamless Rate Switcher – MOTU UltraLite mk5 \(serial)"
    let status = SecItemAdd(add as CFDictionary, nil)
    if status != errSecSuccess { fail(1, "키체인 저장 실패 (OSStatus \(status))") }
}

// MARK: - 프록시 프로토콜 (CueMix 5의 datastore.js / crypto.js / proxy.js와 같은 방식)

/// SubjectPublicKeyInfo DER에서 PKCS#1 RSAPublicKey를 꺼낸다 (SecKey는 PKCS#1만 받는다).
func pkcs1(fromSPKI der: [UInt8]) -> [UInt8]? {
    var i = 0
    func length() -> Int? {
        guard i < der.count else { return nil }
        var len = Int(der[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            len = 0
            for _ in 0..<n {
                guard i < der.count else { return nil }
                len = len << 8 | Int(der[i]); i += 1
            }
        }
        return len
    }
    guard der.first == 0x30 else { return nil }
    i = 1; _ = length()                                                      // SEQUENCE
    guard i < der.count, der[i] == 0x30 else { return nil }
    i += 1
    guard let algorithm = length() else { return nil }
    i += algorithm                                                           // AlgorithmIdentifier
    guard i < der.count, der[i] == 0x03 else { return nil }                  // BIT STRING
    i += 1
    guard let bits = length(), i < der.count, der[i] == 0x00 else { return nil }
    i += 1
    guard i + bits - 1 <= der.count else { return nil }
    return Array(der[i..<(i + bits - 1)])
}

func publicKey(fromPEM pem: String) -> SecKey? {
    let base64 = pem.replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
        .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
        .filter { !$0.isWhitespace && $0 != "\0" }
    guard let der = Data(base64Encoded: base64), let rsa = pkcs1(fromSPKI: [UInt8](der)) else { return nil }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    return SecKeyCreateWithData(Data(rsa) as CFData, attributes as CFDictionary, nil)
}

final class ProxyClient {
    var onProperty: ((Int, [UInt8]) -> Void)?
    var onAuthenticated: (() -> Void)?
    var passwordHash: () -> String?

    private let task: URLSessionWebSocketTask
    private var key: SecKey?
    private var authAttempts = 0
    private var authenticated = false

    init(serial: String, passwordHash: @escaping () -> String?) {
        self.passwordHash = passwordHash
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

    private func handle(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        let id = Int(bytes[0]) << 8 | Int(bytes[1])
        let body = Array(bytes.dropFirst(2))
        if id == 0xFFFE {
            handleProxyMessage(body)
            return
        }
        if !authenticated {
            authenticated = true
            onAuthenticated?()
        }
        onProperty?(id, body)
    }

    private func handleProxyMessage(_ body: [UInt8]) {
        guard body.count >= 2 else { return }
        let message = Int(body[0]) << 8 | Int(body[1])
        let rest = Array(body.dropFirst(2))
        switch message {
        case 6:  // kPublicKeySetup
            key = publicKey(fromPEM: String(decoding: rest, as: UTF8.self))
            if key == nil { fail(1, "프록시 공개키를 읽지 못했습니다") }
        case 0:  // kAuthRequest (두 번째부터는 앞 인증이 틀렸다는 뜻)
            authAttempts += 1
            if authAttempts > 1 { fail(3, "인증 실패: 저장된 비밀번호가 맞지 않습니다. motu-ultralite-mk5 set-password로 다시 저장하세요.") }
            guard let hash = passwordHash() else {
                fail(2, "비밀번호가 없습니다. 먼저 터미널에서 motu-ultralite-mk5 set-password \(serial) 를 실행하세요.")
            }
            sendAuth(hash)
        default:
            break
        }
    }

    /// CueMix: sha256(password)의 16진수 문자열을 RSA-OAEP(SHA-1)로 암호화해 [FFFE][0001][길이][암호문]
    private func sendAuth(_ hash: String) {
        guard let key else { fail(1, "공개키 없이 인증 요청을 받았습니다") }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(hash.utf8) as CFData, &error) as Data? else {
            fail(1, "암호화 실패")
        }
        let message = [0xFF, 0xFE, 0x00, 0x01, UInt8(cipher.count >> 8), UInt8(cipher.count & 0xFF)] + [UInt8](cipher)
        task.send(.data(Data(message))) { error in
            if let error { fail(1, "인증 응답 전송 실패: \(error.localizedDescription)") }
        }
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// 속성 값 바이트의 마지막 값(정수). 앞 2바이트는 길이/플래그로 보인다.
func value(_ bytes: [UInt8]) -> Int {
    bytes.dropFirst(2).reduce(0) { $0 << 8 | Int($1) }
}

// MARK: - 명령

switch command {
case "set-password":
    guard let raw = getpass("MOTU(CueMix) 비밀번호 – \(serial) (화면에 표시 안 됨): ") else { exit(1) }
    let password = String(cString: raw)
    memset(raw, 0, strlen(raw))
    let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    let client = ProxyClient(serial: serial) { hash }
    client.onAuthenticated = {
        storeHash(hash)
        print("인증 성공. 키체인에 저장했습니다 (서비스: \(keychainService), 계정: \(serial)).")
        exit(0)
    }
    client.start()

case "watch":
    let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    var changedAt: Date?
    let client = ProxyClient(serial: serial, passwordHash: storedHash)
    client.onAuthenticated = { print("연결됨. 샘플레이트를 바꾸면 시점을 출력합니다 (Ctrl-C로 종료).") }
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
    let client = ProxyClient(serial: serial, passwordHash: storedHash)
    client.onProperty = { id, bytes in
        guard id == Prop.outputReady, value(bytes) == 1 else { return }
        info(String(format: "준비 신호 수신 (%.2fs)", Date().timeIntervalSince(started)))
        exit(0)
    }
    client.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        fail(4, String(format: "%.0f초 안에 준비 신호가 오지 않았습니다", timeout))
    }
}

dispatchMain()
