import Foundation

/// 샘플레이트를 바꾼 뒤 "출력 준비됐다"를 판단하는 사용자 스크립트.
/// 인터페이스마다 준비 신호를 알아내는 방법이 달라서 앱은 실행만 하고, 판단은 스크립트에 맡긴다.
/// 스크립트가 exit 0으로 끝나면 준비된 것으로 보고 바로 재생한다.
///
/// 스크립트에 넘기는 환경 변수:
///   SRS_SAMPLE_RATE  새 샘플레이트 (예: 96000)
///   SRS_DEVICE_UID   Core Audio 장치 UID (예: com_motu_driver_gen5_control_interface:ul5xxxxxxx)
///   SRS_DEVICE_NAME  장치 이름
public final class ReadyScript {
    public enum Outcome {
        case ready
        case failed(String)   // 실행 실패, exit 코드가 0이 아님, 시간 초과
    }

    private let process = Process()
    private var finished = false

    /// completion은 main 큐에서 한 번만 불린다.
    public init(url: URL, environment: [String: String], timeout: TimeInterval, completion: @escaping (Outcome) -> Void) {
        let isExecutable = FileManager.default.isExecutableFile(atPath: url.path)
        // 실행 권한이 없는 셸 스크립트도 받아 준다
        process.executableURL = isExecutable ? url : URL(fileURLWithPath: "/bin/sh")
        process.arguments = isExecutable ? [] : [url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        let finish = { [weak self] (outcome: Outcome) in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                self.finished = true
                completion(outcome)
            }
        }
        process.terminationHandler = { process in
            if process.terminationStatus == 0 {
                finish(.ready)
            } else {
                // 스크립트가 stderr에 남긴 마지막 줄을 이유로 보여 준다
                let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let last = text.split(separator: "\n").last.map(String.init) ?? ""
                finish(.failed("exit \(process.terminationStatus)" + (last.isEmpty ? "" : ": \(last)")))
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished, self.process.isRunning else { return }
            self.process.terminate()
            finish(.failed(String(format: "timeout %.0fs", timeout)))
        }
    }

    /// 더 새로운 전환이 시작돼 결과가 필요 없어졌을 때
    public func cancel() {
        finished = true
        if process.isRunning { process.terminate() }
    }
}
