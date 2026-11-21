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

    static func symbol(for name: String) -> String {
        name.lowercased().contains("ipad") ? "ipad" : "iphone"
    }
}

struct HotspotUnavailableError: LocalizedError {
    var errorDescription: String? { "개인용 핫스팟 API를 사용할 수 없음" }
}

@MainActor @Observable
final class HotspotService {
    private let browser = ATHotspotBrowser()
    private(set) var devices: [HotspotDevice] = []

    var isAvailable: Bool { browser.isAvailable }

    func start() {
        KnownHotspots.names = Set(Defaults[.priority].map(\.name))
        #if DEBUG
        if DemoMode.isActive {
            devices = DemoMode.devices
            return
        }
        #endif
        guard browser.isAvailable else {
            log("Instant Hotspot API를 찾을 수 없음 — 저장된 Wi-Fi 연결 방식만 사용", .warning)
            return
        }
        browser.onDevicesChanged = { [weak self] list in
            guard let self else { return }
            let found = list.map {
                HotspotDevice(id: $0.identifier, name: $0.name, model: $0.model,
                              battery: $0.batteryLife, signal: $0.signalStrength)
            }
            let known = Set(devices.map(\.name))
            for name in Set(found.map(\.name)).subtracting(known) { log("주변 기기 발견: \(name)") }
            devices = found
            KnownHotspots.names = Set(Defaults[.priority].map(\.name)).union(found.map(\.name))
        }
        browser.start()
    }

    func device(named name: String) -> HotspotDevice? {
        devices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // The first Bluetooth request often fails, so retry a few times.
    func enableHotspot(_ device: HotspotDevice, token: OpToken) async throws -> (ssid: String, password: String?) {
        var lastError: Error = HotspotUnavailableError()
        for attempt in 1...3 {
            guard token.isValid else { throw CancellationError() }
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
                if let ssid {
                    cont.resume(returning: (ssid, password))
                } else {
                    cont.resume(throwing: error ?? HotspotUnavailableError())
                }
            }
        }
    }
}
