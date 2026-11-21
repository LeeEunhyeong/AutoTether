import Foundation
import CoreLocation
import UserNotifications
import Observation

/// macOS 14+에서 Wi-Fi SSID를 읽으려면 위치 권한이 필요
@MainActor @Observable
final class LocationAuth: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    var isAuthorized: Bool { status == .authorizedAlways || status.rawValue == 4 }
    var statusText: String {
        switch status {
        case .authorizedAlways: "허용됨"
        case .denied: "거부됨"
        case .restricted: "제한됨"
        default: isAuthorized ? "허용됨" : "요청 전"
        }
    }

    func request() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if status == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
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
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

import AppKit
