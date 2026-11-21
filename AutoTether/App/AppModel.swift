import SwiftUI
import Observation
import Defaults
import LaunchAtLogin

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Section: String, CaseIterable, Identifiable {
        case dashboard, devices, settings, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: "대시보드"
            case .devices: "기기 우선순위"
            case .settings: "설정"
            case .activity: "활동 기록"
            }
        }
        var symbol: String {
            switch self {
            case .dashboard: "chart.bar.xaxis"
            case .devices: "list.number"
            case .settings: "gearshape"
            case .activity: "clock.arrow.circlepath"
            }
        }
    }

    let activity = ActivityLog.shared
    let hotspots = HotspotService()
    let engine: TetherEngine
    let usage = UsageTracker()
    let sleep = SleepGuard(passive: AppModel.isDiagnostic)
    let location = LocationAuth()
    var section: Section = .dashboard

    private var started = false

    static var isDiagnostic: Bool {
        #if DEBUG
        DebugCLI.isActive
        #else
        false
        #endif
    }

    private init() {
        engine = TetherEngine(hotspots: hotspots)
    }

    func start() {
        guard !started else { return }
        started = true
        log("AutoTether 시작 (v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))")

        let diagnostic = Self.isDiagnostic

        if Defaults[.priority].isEmpty && !diagnostic {
            Task { [weak self] in
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, Defaults[.priority].isEmpty else { return }
                    let found = self.hotspots.devices.sorted { ($0.isPad ? 1 : 0, $0.name) < ($1.isPad ? 1 : 0, $1.name) }
                    if !found.isEmpty {
                        Defaults[.priority] = found.map { PriorityItem(name: $0.name) }
                        log("주변 기기로 우선순위 자동 구성: \(found.map(\.name).joined(separator: " → "))", .success)
                        return
                    }
                }
            }
        }

        if !Defaults[.didFirstLaunch] && !diagnostic {
            Defaults[.didFirstLaunch] = true
            LaunchAtLogin.isEnabled = true
            log("로그인 시 자동 실행 등록")
            Notifier.requestPermission()
            location.request()
        }

        usage.deviceName = { [unowned self] in self.engine.tetherDeviceName }
        usage.canReadSSID = { [unowned self] in self.location.isAuthorized }
        hotspots.start()
        if !diagnostic { engine.start() }
        usage.start()

        guard !diagnostic else { return }

        // Undo anything the sudoers-based version left on before the helper takes over.
        sleep.restoreLegacyIfNeeded()

        Task { [weak self] in
            for await enabled in Defaults.updates(.isEnabled, initial: false) {
                if !enabled { self?.engine.cancelPending("자동 테더링 OFF", autoOnly: true) }
            }
        }

        // Record the intent right away; reconcile can be stuck behind an auth sheet.
        Task { [weak self] in
            for await on in Defaults.updates(.preventLidSleep, initial: false) {
                guard let self else { return }
                if on { self.sleep.userEnabledLidSleep() } else { self.sleep.userDisabledLidSleep() }
                Task { await self.sleep.reconcile(isTethered: self.engine.snapshot.isTethered) }
            }
        }
        Task { [weak self] in
            for await _ in Defaults.updates([.lidSleepOnlyWhileTethered, .lidSleepBatteryFloor]) {
                guard let self else { return }
                await self.sleep.reconcile(isTethered: self.engine.snapshot.isTethered)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                await self.sleep.reconcile(isTethered: self.engine.snapshot.isTethered)
            }
        }
    }

    var menuSymbol: String {
        guard Defaults[.isEnabled] else { return "pause.circle" }
        switch engine.status {
        case .tethered: return "personalhotspot"
        case .connecting, .returning: return "arrow.triangle.2.circlepath"
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .noInternet: return "wifi.exclamationmark"
        case .offline, .wifiOff: return "wifi.slash"
        }
    }
}

extension TetherEngine.Status {
    var title: String {
        switch self {
        case .wifi(let ssid):
            #if DEBUG
            if DemoMode.isActive { return "Wi-Fi · \(DemoMode.ssid)" }
            #endif
            return ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi 연결됨"
        case .ethernet: return "유선 네트워크 연결됨"
        case .tethered(let name): return "\(name) 테더링 중"
        case .noInternet: return "인터넷 연결 없음"
        case .offline: return "네트워크 끊김"
        case .wifiOff: return "Wi-Fi 꺼짐"
        case .connecting(let name): return "\(name)에 연결 중…"
        case .returning(let ssid): return "\(ssid)로 복귀 중…"
        }
    }

    var subtitle: String {
        switch self {
        case .wifi: "정상 — Wi-Fi가 끊기면 자동으로 핫스팟에 연결합니다"
        case .ethernet: "정상"
        case .tethered: "개인용 핫스팟으로 인터넷 사용 중"
        case .noInternet: "Wi-Fi는 연결됐지만 인터넷이 안 됩니다"
        case .offline: "잠시 후 우선순위대로 핫스팟 연결을 시도합니다"
        case .wifiOff: "Wi-Fi를 켜면 자동 테더링이 동작합니다"
        case .connecting: "핫스팟을 켜고 연결하는 중"
        case .returning: "저장된 Wi-Fi로 돌아가는 중"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .tethered: "personalhotspot"
        case .noInternet: "wifi.exclamationmark"
        case .offline, .wifiOff: "wifi.slash"
        case .connecting, .returning: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .wifi, .ethernet: .blue
        case .tethered: .green
        case .noInternet: .orange
        case .offline, .wifiOff: .red
        case .connecting, .returning: .purple
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .returning: true
        default: false
        }
    }
}
