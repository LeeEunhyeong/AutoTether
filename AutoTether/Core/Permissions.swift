import AppKit
import CoreLocation
import Observation
import UserNotifications

// Reading the Wi-Fi SSID requires location access on recent macOS.
@MainActor @Observable
final class LocationAuth: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    // .authorizedWhenInUse is unavailable on macOS but can still be reported (raw value 4).
    var isAuthorized: Bool { status == .authorizedAlways || status.rawValue == 4 }

    var statusText: String {
        switch status {
        case .denied: "거부됨"
        case .restricted: "제한됨"
        default: isAuthorized ? "허용됨" : "요청 전"
        }
    }

    func request() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
