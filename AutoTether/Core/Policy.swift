import Foundation
import CoreWLAN

// 순수 판단 로직 (부작용 없음) — 단위 테스트 대상.
// CoreWLAN 객체(CWNetwork)는 직접 만들 수 없으므로 값 타입(APInfo)으로 옮겨 판단한다.

/// 스캔된 AP 한 개의 판단용 정보
struct APInfo: Hashable, Sendable {
    var ssid: String?
    var bssid: String?
    var rssi: Int
    /// AP가 광고하는 보안 방식 전체 (CoreWLAN supportsSecurity가 true인 것)
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
    /// 핫스팟 후보: WPA2/WPA3 개인용만. 개방형·WEP·OWE·엔터프라이즈를 하나라도 광고하면 거부.
    /// 실측(iOS 26): 진짜 핫스팟은 wpaPersonalMixed·wpa2Personal·personal·wpa3Personal·wpa3Transition을 함께 광고
    /// → wpaPersonalMixed는 거부 기준으로 쓰면 안 됨.
    static let hotspotRequired: Set<CWSecurity> = [.wpa2Personal, .wpa3Personal]
    static let hotspotForbidden: Set<CWSecurity> = [.none, .WEP, .dynamicWEP, .OWE, .oweTransition,
                                                    .enterprise, .wpaEnterprise, .wpaEnterpriseMixed,
                                                    .wpa2Enterprise, .wpa3Enterprise]

    static func isPersonalWPA(_ ap: APInfo) -> Bool {
        !ap.securities.isDisjoint(with: hotspotRequired) && ap.securities.isDisjoint(with: hotspotForbidden)
    }

    /// 실측: WPA2 전용 AP도 wpa3Transition을 true로 돌려줌 → SAE는 wpa3Personal로만 판별
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

    /// 순위: WPA3 > 신호 세기 > 최근 BSSID(동률 깨기). 예전 BSSID를 흉내 낸 AP가 앞서지 않도록 BSSID는 최하위.
    static func bestHotspot(_ accepted: [APInfo], preferredBSSIDs: Set<String>) -> APInfo? {
        func rank(_ a: APInfo) -> (Int, Int, Int) {
            (supportsWPA3(a) ? 1 : 0, a.rssi, a.bssid.map { preferredBSSIDs.contains($0) } == true ? 1 : 0)
        }
        return accepted.max { rank($0) < rank($1) }
    }

    /// 연결된 상태의 보안 방식이 핫스팟으로 허용되는지
    static func hotspotAssociationAllowed(_ sec: CWSecurity?, requireSAE: Bool) -> Bool {
        guard let sec else { return false }
        if requireSAE { return sec == .wpa3Personal }
        return [.wpa2Personal, .wpa3Personal, .wpa3Transition, .personal, .wpaPersonalMixed].contains(sec)
    }

    /// 일반 Wi-Fi 복귀 후보: WPA2/WPA3 개인용·엔터프라이즈만 (개방형·OWE·WEP 거부)
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

    /// 범위 내 저장 Wi-Fi 중 복귀 후보 (신호 강한 순, 중복 제거).
    /// 같은 이름으로 약한 보안 AP가 하나라도 보이면 그 SSID 전체를 제외 (Evil Twin 의심).
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

/// 테더링 인터페이스 판별 (NetworkSnapshot에서 사용)
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

    ///  1) 구형 iOS 핫스팟/USB: 172.20.10.x 주소 + 실제 기본 경로 + (expensive 또는 iPhone/iPad 인터페이스)
    ///  2) 최신 iOS 핫스팟: IPv6 전용 + CLAT → macOS가 'expensive' 경로로 표시
    ///  이름(SSID)·주소 대역 단독으로는 판정하지 않음.
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

/// 인터페이스 카운터 차이 → 사용량 (카운터 리셋·이상치 처리)
enum UsageMath {
    struct Delta: Equatable { var rx: Int64; var tx: Int64; var plausible: Bool }

    /// 1 Gbps 초과 순간값은 이상치로 버림 (Double로 먼저 검사해 Int64 변환 오버플로 방지).
    /// 카운터가 줄었으면(리셋) nil → 기준점을 다시 잡아야 함.
    static func delta(prevRx: UInt64, prevTx: UInt64, rx: UInt64, tx: UInt64, seconds: TimeInterval) -> Delta? {
        guard rx >= prevRx, tx >= prevTx else { return nil }
        let drx = rx - prevRx, dtx = tx - prevTx
        let dt = max(seconds, 0.5)
        let plausible = (Double(drx) + Double(dtx)) / dt < 125_000_000
        return plausible ? Delta(rx: Int64(drx), tx: Int64(dtx), plausible: true) : Delta(rx: 0, tx: 0, plausible: false)
    }

    /// 시간 버킷 시작 (UTC 기준 정시)
    static func hourBucket(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 3600) * 3600 }
}
