import Foundation
import CoreWLAN

struct APInfo: Hashable, Sendable {
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var securities: Set<CWSecurity>
}

extension CWSecurity: @retroactive Hashable {}

extension APInfo {
    static let allSecurities: [CWSecurity] = [
        .none, .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .dynamicWEP,
        .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise,
        .wpa3Personal, .wpa3Enterprise, .wpa3Transition, .OWE, .oweTransition,
    ]

    init(_ n: CWNetwork) {
        self.init(ssid: n.ssid, bssid: n.bssid?.lowercased(), rssi: n.rssiValue,
                  securities: Set(Self.allSecurities.filter(n.supportsSecurity)))
    }
}

enum SecurityPolicy {
    // iOS hotspots also advertise wpaPersonalMixed, so that can't be on the forbidden list.
    static let hotspotRequired: Set<CWSecurity> = [.wpa2Personal, .wpa3Personal]
    static let hotspotForbidden: Set<CWSecurity> = [.none, .WEP, .dynamicWEP, .OWE, .oweTransition,
                                                    .enterprise, .wpaEnterprise, .wpaEnterpriseMixed,
                                                    .wpa2Enterprise, .wpa3Enterprise]

    static func isPersonalWPA(_ ap: APInfo) -> Bool {
        !ap.securities.isDisjoint(with: hotspotRequired) && ap.securities.isDisjoint(with: hotspotForbidden)
    }

    // WPA2-only APs report .wpa3Transition too; only .wpa3Personal means SAE.
    static func supportsWPA3(_ ap: APInfo) -> Bool { ap.securities.contains(.wpa3Personal) }

    struct Selection: Equatable {
        var accepted: [APInfo]
        var rejectedSecurity: Int
        var rejectedNoWPA3: Int
    }

    static func selectHotspotCandidates(_ named: [APInfo], requireWPA3: Bool) -> Selection {
        let safe = named.filter(isPersonalWPA)
        let accepted = requireWPA3 ? safe.filter(supportsWPA3) : safe
        return Selection(accepted: accepted, rejectedSecurity: named.count - safe.count,
                         rejectedNoWPA3: safe.count - accepted.count)
    }

    // BSSID is the last tie-breaker so a spoofed old BSSID can't outrank a stronger real AP.
    static func bestHotspot(_ accepted: [APInfo], preferredBSSIDs: Set<String>) -> APInfo? {
        func rank(_ a: APInfo) -> (Int, Int, Int) {
            (supportsWPA3(a) ? 1 : 0, a.rssi, a.bssid.map { preferredBSSIDs.contains($0) } == true ? 1 : 0)
        }
        return accepted.max { rank($0) < rank($1) }
    }

    static func hotspotAssociationAllowed(_ sec: CWSecurity?, requireSAE: Bool) -> Bool {
        guard let sec else { return false }
        if requireSAE { return sec == .wpa3Personal }
        return [.wpa2Personal, .wpa3Personal, .wpa3Transition, .personal, .wpaPersonalMixed].contains(sec)
    }

    static let returnWeak: Set<CWSecurity> = [.none, .WEP, .dynamicWEP, .OWE, .oweTransition]
    static let returnStrong: Set<CWSecurity> = [.wpa2Personal, .wpa3Personal, .wpa2Enterprise, .wpa3Enterprise, .enterprise]

    static func isSecureForReturn(_ ap: APInfo) -> Bool {
        !ap.securities.isDisjoint(with: returnStrong) && ap.securities.isDisjoint(with: returnWeak)
    }

    static func associationIsStrong(_ sec: CWSecurity?) -> Bool {
        guard let sec else { return false }
        return [.wpa2Personal, .wpa3Personal, .wpa3Transition, .personal, .wpaPersonalMixed,
                .wpa2Enterprise, .wpa3Enterprise, .enterprise].contains(sec)
    }

    // Drops an SSID entirely if any AP with that name advertises weak security.
    static func returnCandidates(_ scanned: [APInfo], known: Set<String>, minRSSI: Int) -> [String] {
        let named = scanned.filter { $0.ssid.map(known.contains) ?? false }
        let tainted = Set(named.filter { !isSecureForReturn($0) }.compactMap(\.ssid))
        var seen = Set<String>()
        return named
            .filter { isSecureForReturn($0) && $0.rssi >= minRSSI && !tainted.contains($0.ssid ?? "") }
            .sorted { $0.rssi > $1.rssi }
            .compactMap(\.ssid)
            .filter { seen.insert($0).inserted }
    }
}

enum TetherClassifier {
    struct Input {
        var addresses: [String: String]
        var primaryInterface: String?
        var pathInterface: String?
        var pathSatisfied: Bool
        var pathExpensive: Bool
        var wifiInterface: String?
        var linkInterface: String?
        var isAppleDevice: (String) -> Bool
    }

    static func tetherInterface(_ i: Input) -> String? {
        if let legacy = i.addresses.sorted(by: { $0.key < $1.key }).first(where: { $0.value.hasPrefix("172.20.10.") })?.key,
           legacy != i.wifiInterface, legacy == i.primaryInterface || legacy == i.pathInterface,
           i.pathExpensive || i.isAppleDevice(legacy) {
            return legacy
        }
        if i.pathSatisfied && i.pathExpensive, let p = i.pathInterface ?? i.linkInterface {
            return p
        }
        return nil
    }
}

enum UsageMath {
    struct Delta: Equatable { var rx: Int64; var tx: Int64; var plausible: Bool }

    static func delta(prevRx: UInt64, prevTx: UInt64, rx: UInt64, tx: UInt64, seconds: TimeInterval) -> Delta? {
        guard rx >= prevRx, tx >= prevTx else { return nil }
        let drx = rx - prevRx, dtx = tx - prevTx
        let dt = max(seconds, 0.5)
        let plausible = (Double(drx) + Double(dtx)) / dt < 125_000_000
        return plausible ? Delta(rx: Int64(drx), tx: Int64(dtx), plausible: true) : Delta(rx: 0, tx: 0, plausible: false)
    }

    static func hourBucket(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 3600) * 3600 }
}
