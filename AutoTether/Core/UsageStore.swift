import Foundation
import GRDB

struct UsageBucket: Hashable {
    let date: Date
    let device: String
    let rx: Int64
    let tx: Int64
    var total: Int64 { rx + tx }
}

struct TetherSession: Identifiable, Hashable, FetchableRecord, Decodable {
    let id: Int64
    let device: String
    let start: Date
    let end: Date
    let rx: Int64
    let tx: Int64
    var total: Int64 { rx + tx }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct UsageTotals: Hashable {
    var rx: Int64 = 0
    var tx: Int64 = 0
    var seconds: TimeInterval = 0
    var total: Int64 { rx + tx }
}

final class UsageStore: @unchecked Sendable {
    let db: DatabaseQueue

    convenience init(fileName: String = "usage.sqlite") throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AutoTether", directoryHint: .isDirectory)
        try self.init(directory: dir, fileName: fileName)
    }

    init(directory dir: URL, fileName: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        db = try DatabaseQueue(path: dir.appending(path: fileName).path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appending(path: fileName).path)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE usage (
                    hour INTEGER NOT NULL,
                    device TEXT NOT NULL,
                    rx INTEGER NOT NULL DEFAULT 0,
                    tx INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (hour, device)
                );
                CREATE TABLE session (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device TEXT NOT NULL,
                    start DOUBLE NOT NULL,
                    "end" DOUBLE NOT NULL,
                    rx INTEGER NOT NULL DEFAULT 0,
                    tx INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX session_start ON session(start);
                """)
        }
        try migrator.migrate(db)
    }

    // MARK: - Writing

    func add(device: String, rx: Int64, tx: Int64, at date: Date) {
        let hour = UsageMath.hourBucket(date)
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO usage(hour, device, rx, tx) VALUES (?, ?, ?, ?)
                ON CONFLICT(hour, device) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                """, arguments: [hour, device, rx, tx])
        }
    }

    func startSession(device: String, at date: Date) -> Int64? {
        try? db.write { db in
            try db.execute(sql: "INSERT INTO session(device, start, \"end\") VALUES (?, ?, ?)",
                           arguments: [device, date.timeIntervalSince1970, date.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    func updateSession(id: Int64, device: String, end: Date, rx: Int64, tx: Int64) {
        try? db.write { db in
            try db.execute(sql: "UPDATE session SET device = ?, \"end\" = ?, rx = ?, tx = ? WHERE id = ?",
                           arguments: [device, end.timeIntervalSince1970, rx, tx, id])
        }
    }

    enum RecordResult { case ok, sessionMissing, failed }

    func record(sessionID: Int64, device: String, rx: Int64, tx: Int64, at date: Date,
                sessionRx: Int64, sessionTx: Int64) -> RecordResult {
        struct Missing: Error {}
        let hour = UsageMath.hourBucket(date)
        do {
            try db.write { db in
                try db.execute(sql: "UPDATE session SET \"end\" = ?, rx = ?, tx = ? WHERE id = ?",
                               arguments: [date.timeIntervalSince1970, sessionRx, sessionTx, sessionID])
                guard db.changesCount == 1 else { throw Missing() }
                if rx > 0 || tx > 0 {
                    try db.execute(sql: """
                        INSERT INTO usage(hour, device, rx, tx) VALUES (?, ?, ?, ?)
                        ON CONFLICT(hour, device) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx
                        """, arguments: [hour, device, rx, tx])
                }
            }
            return .ok
        } catch is Missing {
            return .sessionMissing
        } catch {
            return .failed
        }
    }

    @discardableResult
    func resetAll() -> Bool {
        do {
            try db.write { db in try db.execute(sql: "DELETE FROM usage; DELETE FROM session;") }
            return true
        } catch {
            return false
        }
    }

    func seedDemoData() {
        resetAll()
        let now = Date()
        let devices = ["iPhone", "iPad"]
        for dayOffset in 0..<30 {
            for h in stride(from: 9, to: 23, by: Int.random(in: 1...3)) {
                guard let t = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Calendar.current.startOfDay(for: now))?
                    .addingTimeInterval(TimeInterval(h * 3600)), t < now else { continue }
                let dev = devices[Int.random(in: 0...3) == 0 ? 1 : 0]
                add(device: dev, rx: Int64.random(in: 20_000_000...400_000_000), tx: Int64.random(in: 2_000_000...40_000_000), at: t)
                if Int.random(in: 0...4) == 0, let id = startSession(device: dev, at: t) {
                    updateSession(id: id, device: dev, end: t.addingTimeInterval(TimeInterval.random(in: 600...7200)),
                                  rx: Int64.random(in: 50_000_000...900_000_000), tx: Int64.random(in: 5_000_000...60_000_000))
                }
            }
        }
    }

    // MARK: - Reading

    func hourly(since: Date?) -> [UsageBucket] {
        let from = Int64((since ?? .distantPast).timeIntervalSince1970.clamped(min: 0))
        return (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT hour, device, rx, tx FROM usage WHERE hour >= ? ORDER BY hour",
                             arguments: [from / 3600 * 3600])
                .map { row in
                    UsageBucket(date: Date(timeIntervalSince1970: TimeInterval(row["hour"] as Int64)),
                                device: row["device"], rx: row["rx"], tx: row["tx"])
                }
        }) ?? []
    }

    func daily(since: Date?) -> [UsageBucket] {
        let cal = Calendar.current
        var map: [String: [Date: (Int64, Int64)]] = [:]
        for b in hourly(since: since) {
            let day = cal.startOfDay(for: b.date)
            let cur = map[b.device, default: [:]][day] ?? (0, 0)
            map[b.device, default: [:]][day] = (cur.0 + b.rx, cur.1 + b.tx)
        }
        return map.flatMap { device, days in
            days.map { UsageBucket(date: $0.key, device: device, rx: $0.value.0, tx: $0.value.1) }
        }.sorted { $0.date < $1.date }
    }

    func totals(since: Date?) -> UsageTotals {
        let from = (since ?? .distantPast).timeIntervalSince1970.clamped(min: 0)
        return (try? db.read { db in
            var t = UsageTotals()
            if let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(rx),0) AS rx, COALESCE(SUM(tx),0) AS tx FROM usage WHERE hour >= ?",
                                          arguments: [Int64(from) / 3600 * 3600]) {
                t.rx = row["rx"]; t.tx = row["tx"]
            }
            t.seconds = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(MAX(0, \"end\" - MAX(start, ?))),0) FROM session WHERE \"end\" >= ?",
                                            arguments: [from, from]) ?? 0
            return t
        }) ?? UsageTotals()
    }

    func byDevice(since: Date?) -> [(device: String, total: Int64)] {
        let from = Int64((since ?? .distantPast).timeIntervalSince1970.clamped(min: 0))
        return (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT device, SUM(rx + tx) AS t FROM usage WHERE hour >= ? GROUP BY device ORDER BY t DESC",
                             arguments: [from / 3600 * 3600])
                .map { (device: $0["device"] as String, total: $0["t"] as Int64) }
        }) ?? []
    }

    func sessions(limit: Int = 50) -> [TetherSession] {
        (try? db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM session ORDER BY start DESC LIMIT ?", arguments: [limit]).map { row in
                TetherSession(id: row["id"], device: row["device"],
                              start: Date(timeIntervalSince1970: row["start"]),
                              end: Date(timeIntervalSince1970: row["end"]),
                              rx: row["rx"], tx: row["tx"])
            }
        }) ?? []
    }
}

extension Double {
    func clamped(min lower: Double) -> Double { Swift.max(self, lower) }
}

extension Date {
    static var startOfMonth: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
    }
}
