import XCTest

final class UsageStoreTests: XCTestCase {
    var dir: URL!
    var store: UsageStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "AutoTetherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try UsageStore(directory: dir, fileName: "test.sqlite")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecordAccumulatesIntoHourBucketAndSession() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try XCTUnwrap(store.startSession(device: "iPad", at: t0))
        XCTAssertEqual(store.record(sessionID: id, device: "iPad", rx: 100, tx: 10, at: t0.addingTimeInterval(2),
                                    sessionRx: 100, sessionTx: 10), .ok)
        XCTAssertEqual(store.record(sessionID: id, device: "iPad", rx: 50, tx: 5, at: t0.addingTimeInterval(4),
                                    sessionRx: 150, sessionTx: 15), .ok)

        let totals = store.totals(since: nil)
        XCTAssertEqual(totals.rx, 150)
        XCTAssertEqual(totals.tx, 15)
        XCTAssertEqual(totals.seconds, 4, accuracy: 0.001)

        let s = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(s.total, 165)
        XCTAssertEqual(s.duration, 4, accuracy: 0.001)
    }

    func testMissingSessionRollsBackWholeSample() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try XCTUnwrap(store.startSession(device: "iPad", at: t0))
        XCTAssertTrue(store.resetAll())
        XCTAssertEqual(store.record(sessionID: id, device: "iPad", rx: 999, tx: 999, at: t0,
                                    sessionRx: 999, sessionTx: 999), .sessionMissing)
        XCTAssertEqual(store.totals(since: nil).total, 0, "세션이 없으면 사용량도 기록되지 않아야 함(한 트랜잭션)")
    }

    func testByDeviceOrdersByTotal() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(device: "iPhone", rx: 10, tx: 0, at: t)
        store.add(device: "iPad", rx: 500, tx: 0, at: t)
        store.add(device: "iPhone", rx: 20, tx: 0, at: t.addingTimeInterval(3600))
        XCTAssertEqual(store.byDevice(since: nil).map(\.device), ["iPad", "iPhone"])
        XCTAssertEqual(store.byDevice(since: nil).last?.total, 30)
    }

    func testSinceFilterUsesHourBuckets() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(device: "iPad", rx: 1, tx: 0, at: base)
        store.add(device: "iPad", rx: 2, tx: 0, at: base.addingTimeInterval(86_400 * 3))
        XCTAssertEqual(store.totals(since: base.addingTimeInterval(86_400)).rx, 2)
        XCTAssertEqual(store.daily(since: nil).count, 2)
    }

    func testDatabaseFileIsPrivate() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "test.sqlite").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
