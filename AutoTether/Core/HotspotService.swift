import Foundation
import Observation
import Defaults

struct HotspotDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let battery: Int
    let signal: Int

    var isPad: Bool { model.hasPrefix("iPad") }
    var symbol: String { isPad ? "ipad" : "iphone" }
}

enum HotspotError: LocalizedError {
    case unavailable
    var errorDescription: String? { "개인용 핫스팟 API를 사용할 수 없음" }
}

/// 주변 iPhone/iPad (같은 Apple ID) 탐색 및 핫스팟 원격 켜기
@MainActor @Observable
final class HotspotService {
    private let browser = ATHotspotBrowser()
    private(set) var devices: [HotspotDevice] = []
    var isAvailable: Bool { browser.isAvailable }

    func start() {
        KnownHotspots.names = Set(Defaults[.priority].map(\.name))
        #if DEBUG
        if DemoMode.isActive { devices = DemoMode.devices; return }   // 스크린샷: 실제 기기 이름 노출 방지
        #endif
        guard browser.isAvailable else {
            log("Instant Hotspot API를 찾을 수 없음 — 저장된 Wi-Fi 연결 방식만 사용", .warning)
            return
        }
        browser.onDevicesChanged = { [weak self] list in
            guard let self else { return }
            let mapped = list.map {
                HotspotDevice(id: $0.identifier, name: $0.name, model: $0.model,
                              battery: $0.batteryLife, signal: $0.signalStrength)
            }
            let before = Set(self.devices.map(\.name))
            let after = Set(mapped.map(\.name))
            for n in after.subtracting(before) { log("주변 기기 발견: \(n)") }
            self.devices = mapped
            KnownHotspots.names = Set(Defaults[.priority].map(\.name)).union(mapped.map(\.name))
        }
        browser.start()
    }

    func device(named name: String) -> HotspotDevice? {
        devices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// 기기에 핫스팟 켜기를 요청하고 (SSID, 비밀번호)를 받음. 블루투스 특성상 첫 시도 실패가 잦아 최대 3회 재시도.
    func enableHotspot(_ device: HotspotDevice, token: OpToken? = nil) async throws -> (ssid: String, password: String?) {
        var lastError: Error = HotspotError.unavailable
        for attempt in 1...3 {
            if let token, !token.isValid { throw CancellationError() }
            do {
                return try await enableOnce(device)
            } catch {
                lastError = error
                log("\(device.name) 핫스팟 요청 \(attempt)/3 실패: \(error.localizedDescription)", .warning)
                if attempt < 3 { try? await Task.sleep(for: .seconds(4)) }
            }
        }
        throw lastError
    }

    private func enableOnce(_ device: HotspotDevice) async throws -> (ssid: String, password: String?) {
        try await withCheckedThrowingContinuation { cont in
            browser.enableHotspotForDevice(withIdentifier: device.id) { ssid, password, error in
                if let ssid { cont.resume(returning: (ssid, password)) }
                else { cont.resume(throwing: error ?? HotspotError.unavailable) }
            }
        }
    }
}
