import Foundation
import Observation

@MainActor @Observable
final class ActivityLog {
    static let shared = ActivityLog()

    enum Level: String { case info, success, warning, error }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let level: Level
    }

    private(set) var entries: [Entry] = []
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AutoTether.log")
    /// 로그 파일 최대 크기 (넘으면 .1로 회전, 1세대만 보관)
    private let maxBytes: UInt64 = 1_000_000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init() {
        secure(fileURL)
    }

    /// 제어 문자(개행 포함) 제거 → SSID/기기 이름에 의한 로그 위조 방지
    nonisolated static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "␣" : $0 }))
    }

    func log(_ message: String, _ level: Level = .info) {
        let now = Date()
        let clean = Self.sanitize(message)
        entries.insert(Entry(date: now, message: clean, level: level), at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }

        let line = "\(Self.formatter.string(from: now)) [\(level.rawValue)] \(clean)\n"
        if isatty(1) != 0 { FileHandle.standardOutput.write(Data(line.utf8)) }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            // ObjC 예외를 던지는 구형 write(_:) 대신 throwing API 사용 (디스크 가득 참 등에서 크래시 방지)
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(line.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > maxBytes else { return }
        let old = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
        secure(old)
    }

    private func secure(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
func log(_ message: String, _ level: ActivityLog.Level = .info) {
    ActivityLog.shared.log(message, level)
}
