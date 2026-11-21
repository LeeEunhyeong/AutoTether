import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var timedOut = false
        var ok: Bool { status == 0 && !timedOut }
    }

    /// 백그라운드에서 프로세스 실행 (셸을 거치지 않음 → 인자 인젝션 불가)
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> Result {
        await Task.detached(priority: .userInitiated) { runSync(path, args, timeout: timeout) }.value
    }

    /// 제한 시간 초과 시 SIGTERM → SIGKILL. 출력은 64KB까지만 보관. 상속 환경 변수 차단.
    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()   // 부모 쪽 쓰기 끝을 닫아 자식 종료 시 EOF가 오도록

        let buffer = OutputBuffer()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let h = pipe.fileHandleForReading
            // ObjC 예외를 던지는 availableData 대신 throwing API 사용
            while let chunk = try? h.read(upToCount: 16_384), !chunk.isEmpty {
                buffer.append(chunk)
            }
            readDone.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            let pid = task.processIdentifier
            if exited.wait(timeout: .now() + 2) == .timedOut, task.isRunning, pid > 0 {
                kill(pid, SIGKILL)   // 아직 실행 중인 우리 자식일 때만 (PID 재사용/0 방지)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        if readDone.wait(timeout: .now() + 2) == .timedOut {
            try? pipe.fileHandleForReading.close()   // 손자 프로세스가 파이프를 물고 있으면 읽기 스레드 해제
        }
        let out = buffer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: timedOut ? -2 : task.terminationStatus, output: out, timedOut: timedOut)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit = 65_536
        func append(_ chunk: Data) {
            lock.withLock { if data.count < limit { data.append(chunk.prefix(limit - data.count)) } }
        }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
