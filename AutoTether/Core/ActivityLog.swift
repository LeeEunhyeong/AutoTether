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
    let fileURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/AutoTether.log")
    private let maxFileSize: UInt64 = 1_000_000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init() {
        restrictPermissions(fileURL)
    }

    nonisolated static func sanitize(_ s: String) -> String {
        let scalars = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "␣" : $0 }
        return String(String.UnicodeScalarView(scalars))
    }

    func log(_ message: String, _ level: Level = .info) {
        let now = Date()
        let text = Self.sanitize(message)
        entries.insert(Entry(date: now, message: text, level: level), at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }

        let line = Data("\(Self.formatter.string(from: now)) [\(level.rawValue)] \(text)\n".utf8)
        if isatty(1) != 0 { FileHandle.standardOutput.write(line) }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
              size > maxFileSize else { return }
        let old = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
        restrictPermissions(old)
    }

    private func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
func log(_ message: String, _ level: ActivityLog.Level = .info) {
    ActivityLog.shared.log(message, level)
}
