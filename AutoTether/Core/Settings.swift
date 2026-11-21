import Foundation
import Defaults

struct PriorityItem: Codable, Hashable, Identifiable, Defaults.Serializable {
    var id = UUID()
    var name: String
    var enabled = true
}

extension Defaults.Keys {
    static let isEnabled = Key<Bool>("isEnabled", default: true)
    static let priority = Key<[PriorityItem]>("priority", default: [])
    static let returnToWiFi = Key<Bool>("returnToWiFi", default: true)
    static let leaveDeadWiFi = Key<Bool>("leaveDeadWiFi", default: true)
    static let notifyOnSwitch = Key<Bool>("notifyOnSwitch", default: true)
    static let monthlyLimitGB = Key<Double>("monthlyLimitGB", default: 0)
    static let didFirstLaunch = Key<Bool>("didFirstLaunch", default: false)

    static let preventLidSleep = Key<Bool>("preventLidSleep", default: false)
    static let lidSleepOnlyWhileTethered = Key<Bool>("lidSleepOnlyWhileTethered", default: false)
    static let lidSleepBatteryFloor = Key<Int>("lidSleepBatteryFloor", default: 15)

    // Set by the pre-helper (sudoers) versions when they turned sleep off.
    static let weDisabledSleep = Key<Bool>("weDisabledSleep", default: false)
    static let pendingConsentRevoke = Key<Bool>("pendingConsentRevoke", default: false)
    static let helperUpgradeAttemptedFor = Key<String>("helperUpgradeAttemptedFor", default: "")

    // Hotspot SSID -> recently seen BSSIDs. iOS rotates them, so this is only a tie-breaker.
    static let pinnedBSSIDs = Key<[String: [String]]>("pinnedBSSIDs", default: [:])
    // Device name -> false means the user allowed WPA2 for automatic joins.
    static let hotspotWPA3 = Key<[String: Bool]>("hotspotWPA3", default: [:])
}
