import Foundation
import Observation

/// 테더링 중일 때 2초마다 인터페이스 바이트 카운터를 샘플링해 사용량을 누적
@MainActor @Observable
final class UsageTracker {
    let store: UsageStore?

    private(set) var downloadSpeed: Double = 0   // bytes/s
    private(set) var uploadSpeed: Double = 0
    private(set) var sessionRx: Int64 = 0
    private(set) var sessionTx: Int64 = 0
    private(set) var sessionStart: Date?
    /// 대시보드 새로고침 트리거
    private(set) var revision = 0

    /// 현재 테더링 기기 이름 제공자 (엔진이 설정)
    var deviceName: () -> String = { "개인용 핫스팟" }

    private var sessionID: Int64?
    private var sessionKey: String?
    private var sessionDevice = ""
    private var warnedWriteFail = false
    private var last: (key: String, rx: UInt64, tx: UInt64, time: Date)?
    /// 위치 권한이 있어 SSID를 읽을 수 있는지 (전환 순간 감지용)
    var canReadSSID: () -> Bool = { false }
    private var loop: Task<Void, Never>?
    /// 테더링 세션 진행 중 (샘플링 간격 결정)
    var isSampling: Bool { sessionID != nil || last != nil }
    private var ticks = 0

    init() {
        do {
            #if DEBUG
            if DebugCLI.isActive && !CommandLine.arguments.contains("--demo-data") {
                store = try UsageStore(fileName: "usage-diagnostic.sqlite")   // 진단은 실제 사용량 DB를 건드리지 않음
            } else if CommandLine.arguments.contains("--demo-data") {
                let s = try UsageStore(fileName: "usage-demo.sqlite")
                s.seedDemoData()
                store = s
            } else {
                store = try UsageStore()
            }
            #else
            store = try UsageStore()
            #endif
        } catch {
            store = nil
            log("사용량 DB 열기 실패: \(error.localizedDescription)", .error)
        }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                // 테더링 중에만 2초 간격으로 정밀 샘플링. 평소에는 10초마다 확인만 (CPU 깨우기·배터리 절약)
                let active = self?.isSampling ?? false
                try? await Task.sleep(for: .seconds(active ? 2 : 10), tolerance: .seconds(active ? 0.2 : 2))
            }
        }
    }

    func sample() {
        let snap = NetworkSnapshot.current()
        let now = Date()
        guard let iface = snap.tetherInterface else {
            if sessionID != nil { endSession() }
            last = nil
            downloadSpeed = 0; uploadSpeed = 0
            return
        }
        // 네트워크 전환 중(SSID를 읽을 수 있는데 비어 있음)에는 집계하지 않음 → 다른 네트워크 트래픽 혼입 방지
        if iface == snap.wifiInterface, snap.ssid == nil, canReadSSID() {
            last = nil
            return
        }
        var rx: UInt64 = 0, tx: UInt64 = 0
        guard ATReadInterfaceCounters(iface, &rx, &tx) else {
            last = nil   // 기준점을 끊어 다음 성공 샘플에서 새로 시작 (공백 구간을 한 번에 귀속하지 않음)
            downloadSpeed = 0; uploadSpeed = 0
            return
        }
        let key = "\(iface)|\(snap.ssid ?? "")"

        // 연결 대상이 바뀌면 이전 세션을 닫고 새 세션 시작 (A→B 핫스팟 전환 시 사용량 섞임 방지)
        if sessionID != nil, sessionKey != key {
            endSession()
            last = nil
        }
        if sessionID == nil {
            sessionStart = now
            sessionRx = 0; sessionTx = 0
            // 같은 스냅샷에서 기기 이름 결정 (엔진 상태는 전환 중 직전 기기일 수 있음)
            if iface == snap.wifiInterface, let ssid = snap.ssid, KnownHotspots.names.contains(ssid) { sessionDevice = ssid }
            else { sessionDevice = deviceName() }
            sessionKey = key
            sessionID = store?.startSession(device: sessionDevice, at: now)
        }
        if let l = last, l.key == key,
           let d = UsageMath.delta(prevRx: l.rx, prevTx: l.tx, rx: rx, tx: tx, seconds: now.timeIntervalSince(l.time)) {
            let dt = max(now.timeIntervalSince(l.time), 0.5)
            let drx = d.rx, dtx = d.tx
            downloadSpeed = Double(drx) / dt
            uploadSpeed = Double(dtx) / dt
            if let id = sessionID, let store {
                switch store.record(sessionID: id, device: sessionDevice, rx: drx, tx: dtx, at: now,
                                    sessionRx: sessionRx + drx, sessionTx: sessionTx + dtx) {
                case .ok:
                    sessionRx += drx; sessionTx += dtx
                    warnedWriteFail = false
                case .sessionMissing:
                    // 세션 행이 사라짐(초기화 등) → 세션과 기준점을 다시 시작
                    sessionID = nil; sessionKey = nil; last = nil
                    return
                case .failed:
                    if !warnedWriteFail { warnedWriteFail = true; log("사용량 저장 실패 (디스크 공간/권한 확인)", .error) }
                    return   // 기준점을 전진시키지 않음 → 다음 샘플에서 누락분 포함해 재시도
                }
            }
        }
        last = (key, rx, tx, now)
        ticks += 1
        if ticks % 5 == 0 { revision += 1 }   // 10초마다 UI 갱신
    }

    private func endSession() {
        if let id = sessionID, let start = sessionStart {
            store?.updateSession(id: id, device: sessionDevice, end: Date(), rx: sessionRx, tx: sessionTx)
            log("테더링 세션 종료 — \(Format.bytes(sessionRx + sessionTx)), \(Format.duration(Date().timeIntervalSince(start)))")
        }
        sessionID = nil
        sessionStart = nil
        sessionKey = nil
        revision += 1
    }

    func resetAll() {
        guard store?.resetAll() == true else {
            log("사용량 기록 초기화 실패", .error)
            return
        }
        sessionID = nil
        sessionStart = nil
        sessionKey = nil
        last = nil   // 기준점도 초기화 → 삭제 전 트래픽이 다시 합산되지 않음
        sessionRx = 0; sessionTx = 0
        revision += 1
        log("사용량 기록을 초기화함", .warning)
    }
}

enum Format {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .decimal)
    }
    static func speed(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .decimal) + "/s"
    }
    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        var cal = Calendar.current
        cal.locale = Locale(identifier: "ko_KR")
        f.calendar = cal
        return f.string(from: t) ?? "-"
    }
}
