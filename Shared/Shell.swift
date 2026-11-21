import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var timedOut = false
        var ok: Bool { status == 0 && !timedOut }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> Result {
        await Task.detached(priority: .userInitiated) { runSync(path, args, timeout: timeout) }.value
    }

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
        do {
            try task.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()

        let output = OutputBuffer()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                output.append(chunk)
            }
            readDone.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            let pid = task.processIdentifier
            if exited.wait(timeout: .now() + 2) == .timedOut, task.isRunning, pid > 0 {
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        if readDone.wait(timeout: .now() + 2) == .timedOut {
            // A grandchild may still hold the pipe open.
            try? pipe.fileHandleForReading.close()
        }
        let text = output.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: timedOut ? -2 : task.terminationStatus, output: text, timedOut: timedOut)
    }
}
