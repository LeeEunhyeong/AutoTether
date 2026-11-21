import Foundation
import Defaults

struct PriorityItem: Codable, Hashable, Identifiable, Defaults.Serializable {
    var id = UUID()
    var name: String
    var enabled = true
}

extension Defaults.Keys {
    /// 마스터 스위치: 자동 테더링 활성화
    static let isEnabled = Key<Bool>("isEnabled", default: true)
    /// 순서 = 우선순위
    /// 비어 있으면 처음 실행 시 주변에서 발견한 기기(같은 Apple ID)로 자동 구성
    static let priority = Key<[PriorityItem]>("priority", default: [])
    static let returnToWiFi = Key<Bool>("returnToWiFi", default: true)
    static let leaveDeadWiFi = Key<Bool>("leaveDeadWiFi", default: true)
    static let notifyOnSwitch = Key<Bool>("notifyOnSwitch", default: true)

    static let preventLidSleep = Key<Bool>("preventLidSleep", default: false)
    static let lidSleepOnlyWhileTethered = Key<Bool>("lidSleepOnlyWhileTethered", default: false)
    /// 배터리 사용 중 이 % 이하이면 잠자기 방지 자동 해제 (0 = 사용 안 함)
    static let lidSleepBatteryFloor = Key<Int>("lidSleepBatteryFloor", default: 15)
    /// 우리가 pmset disablesleep 1을 걸었는지 (크래시 후 복구용)
    static let weDisabledSleep = Key<Bool>("weDisabledSleep", default: false)
    /// 사용자가 잠자기 방지를 껐는데 헬퍼의 동의 철회가 아직 확인되지 않음 (확인 전에는 다시 켜기 금지)
    static let pendingConsentRevoke = Key<Bool>("pendingConsentRevoke", default: false)
    /// 이 앱 버전에서 헬퍼 교체를 이미 시도했는지
    static let helperUpgradeAttemptedFor = Key<String>("helperUpgradeAttemptedFor", default: "")

    /// 월 데이터 한도 (GB, 0 = 사용 안 함)
    static let monthlyLimitGB = Key<Double>("monthlyLimitGB", default: 0)
    static let didFirstLaunch = Key<Bool>("didFirstLaunch", default: false)

    /// 핫스팟 SSID → 최근 검증된 BSSID (선호 힌트 전용 — iOS가 핫스팟 BSSID를 주기적으로 바꾸므로 강제하지 않음)
    static let pinnedBSSIDs = Key<[String: [String]]>("pinnedBSSIDs", default: [:])
    /// 핫스팟 SSID → WPA3(SAE)로 연결된 적 있음 (능력 TOFU). true면 자동 연결 시 WPA3 미지원 AP를 거부
    static let hotspotWPA3 = Key<[String: Bool]>("hotspotWPA3", default: [:])
}
