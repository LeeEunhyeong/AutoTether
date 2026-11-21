import XCTest
import CoreWLAN

final class SecurityPolicyTests: XCTestCase {
    let iosHotspot: Set<CWSecurity> = [.wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Personal, .wpa3Transition]
    let wpa2Router: Set<CWSecurity> = [.wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Transition]

    func ap(_ sec: Set<CWSecurity>) -> APInfo {
        APInfo(ssid: "iPad", bssid: nil, rssi: -50, securities: sec)
    }
    func ap(bssid: String?, rssi: Int, _ sec: Set<CWSecurity>) -> APInfo {
        APInfo(ssid: "iPad", bssid: bssid, rssi: rssi, securities: sec)
    }
    func ap(_ ssid: String, rssi: Int, _ sec: Set<CWSecurity>) -> APInfo {
        APInfo(ssid: ssid, bssid: nil, rssi: rssi, securities: sec)
    }

    // MARK: - Hotspot candidates

    func testRealHotspotIsAcceptedAndRecognizedAsWPA3() {
        XCTAssertTrue(SecurityPolicy.isPersonalWPA(ap(iosHotspot)))
        XCTAssertTrue(SecurityPolicy.supportsWPA3(ap(iosHotspot)))
    }

    func testWPA3TransitionAloneIsNotTrustedAsWPA3() {
        XCTAssertTrue(SecurityPolicy.isPersonalWPA(ap(wpa2Router)))
        XCTAssertFalse(SecurityPolicy.supportsWPA3(ap(wpa2Router)), "WPA2 전용 AP를 WPA3로 오인하면 다운그레이드 방어가 무력화됨")
    }

    func testWeakOrEnterpriseTwinsAreRejected() {
        let weak: [Set<CWSecurity>] = [[.none], [.WEP], [.OWE], [.oweTransition, .wpa2Personal],
                                       [.wpa2Enterprise], [.wpa2Personal, .none]]
        for sec in weak {
            XCTAssertFalse(SecurityPolicy.isPersonalWPA(ap(sec)), "\(sec.map(\.rawValue)) 는 거부돼야 함")
        }
    }

    func testRequireWPA3RejectsWPA2TwinAndCountsReasons() {
        let r = SecurityPolicy.selectHotspotCandidates([ap(iosHotspot), ap(wpa2Router), ap([.none])], requireWPA3: true)
        XCTAssertEqual(r.accepted.count, 1)
        XCTAssertEqual(r.rejectedSecurity, 1)
        XCTAssertEqual(r.rejectedNoWPA3, 1)
        let loose = SecurityPolicy.selectHotspotCandidates([ap(iosHotspot), ap(wpa2Router)], requireWPA3: false)
        XCTAssertEqual(loose.accepted.count, 2)
    }

    func testRankingPrefersWPA3OverSignalAndBSSIDOnlyBreaksTies() {
        let strongWPA2 = ap(bssid: "aa", rssi: -30, wpa2Router)
        let weakWPA3 = ap(bssid: "bb", rssi: -70, iosHotspot)
        XCTAssertEqual(SecurityPolicy.bestHotspot([strongWPA2, weakWPA3], preferredBSSIDs: ["aa"])?.bssid, "bb")

        let spoof = ap(bssid: "old", rssi: -70, iosHotspot)
        let real = ap(bssid: "new", rssi: -40, iosHotspot)
        XCTAssertEqual(SecurityPolicy.bestHotspot([spoof, real], preferredBSSIDs: ["old"])?.bssid, "new")
        let a = ap(bssid: "x", rssi: -50, iosHotspot), b = ap(bssid: "y", rssi: -50, iosHotspot)
        XCTAssertEqual(SecurityPolicy.bestHotspot([a, b], preferredBSSIDs: ["y"])?.bssid, "y")
        XCTAssertNil(SecurityPolicy.bestHotspot([], preferredBSSIDs: []))
    }

    func testAssociationCheck() {
        XCTAssertTrue(SecurityPolicy.hotspotAssociationAllowed(.wpa3Personal, requireSAE: true))
        XCTAssertFalse(SecurityPolicy.hotspotAssociationAllowed(.wpa2Personal, requireSAE: true))
        XCTAssertTrue(SecurityPolicy.hotspotAssociationAllowed(.wpa2Personal, requireSAE: false))
        XCTAssertFalse(SecurityPolicy.hotspotAssociationAllowed(.none, requireSAE: false))
        XCTAssertFalse(SecurityPolicy.hotspotAssociationAllowed(nil, requireSAE: false))
    }

    // MARK: - Return candidates

    func testReturnCandidatesExcludeTaintedSSIDAndSortBySignal() {
        let scanned = [
            ap("Home_5G", rssi: -60, wpa2Router),
            ap("Home_2.4G", rssi: -45, wpa2Router),
            ap("Home_2.4G", rssi: -50, wpa2Router),
            ap("Cafe", rssi: -40, wpa2Router),
            ap("Cafe", rssi: -80, [.none]),
            ap("Office", rssi: -55, [.wpa2Enterprise]),
            ap("Weak", rssi: -90, wpa2Router),
            ap("Stranger", rssi: -30, wpa2Router),
        ]
        let r = SecurityPolicy.returnCandidates(scanned, known: ["Home_5G", "Home_2.4G", "Cafe", "Office", "Weak"], minRSSI: -72)
        XCTAssertEqual(r, ["Home_2.4G", "Office", "Home_5G"])
    }

    func testReturnRejectsOpenAndOWE() {
        XCTAssertFalse(SecurityPolicy.isSecureForReturn(ap([.none])))
        XCTAssertFalse(SecurityPolicy.isSecureForReturn(ap([.OWE])))
        XCTAssertFalse(SecurityPolicy.associationIsStrong(.none))
        XCTAssertTrue(SecurityPolicy.associationIsStrong(.wpa2Personal))
    }
}

final class TetherClassifierTests: XCTestCase {
    func input(_ mutate: (inout TetherClassifier.Input) -> Void) -> TetherClassifier.Input {
        var i = TetherClassifier.Input(addresses: [:], primaryInterface: nil, pathInterface: nil,
                                       pathSatisfied: false, pathExpensive: false, wifiInterface: "en0",
                                       linkInterface: nil, isAppleDevice: { _ in false })
        mutate(&i)
        return i
    }

    func testModernIPv6OnlyHotspotIsDetectedByExpensivePath() {
        let i = input { $0.pathSatisfied = true; $0.pathExpensive = true; $0.pathInterface = "en0" }
        XCTAssertEqual(TetherClassifier.tetherInterface(i), "en0")
    }

    func testOrdinaryWiFiIsNotTethering() {
        let i = input { $0.addresses = ["en0": "192.168.0.5"]; $0.primaryInterface = "en0"
                        $0.pathSatisfied = true; $0.pathInterface = "en0" }
        XCTAssertNil(TetherClassifier.tetherInterface(i))
    }

    func testRouterHanding172_20_10RangeIsNotTetheringWithoutExpensiveSignal() {
        let i = input { $0.addresses = ["en0": "172.20.10.3"]; $0.primaryInterface = "en0"
                        $0.pathSatisfied = true; $0.pathInterface = "en0" }
        XCTAssertNil(TetherClassifier.tetherInterface(i), "주소 대역만으로 테더링이라고 판정하면 안 됨")
    }

    func testUSBTetherNeedsPrimaryRouteAndAppleDevice() {
        let usb = input { $0.addresses = ["en0": "192.168.0.5", "en7": "172.20.10.2"]; $0.primaryInterface = "en7"
                          $0.isAppleDevice = { $0 == "en7" } }
        XCTAssertEqual(TetherClassifier.tetherInterface(usb), "en7")

        let notPrimary = input { $0.addresses = ["en0": "192.168.0.5", "en7": "172.20.10.2"]; $0.primaryInterface = "en0"
                                 $0.isAppleDevice = { $0 == "en7" } }
        XCTAssertNil(TetherClassifier.tetherInterface(notPrimary))

        let unknownDevice = input { $0.addresses = ["en7": "172.20.10.2"]; $0.primaryInterface = "en7" }
        XCTAssertNil(TetherClassifier.tetherInterface(unknownDevice))
    }

    func testExpensiveButUnsatisfiedPathIsNotTethering() {
        let i = input { $0.pathExpensive = true; $0.pathInterface = "en0" }
        XCTAssertNil(TetherClassifier.tetherInterface(i))
    }
}

final class UsageMathTests: XCTestCase {
    func testNormalDelta() {
        let d = UsageMath.delta(prevRx: 1_000, prevTx: 500, rx: 3_000, tx: 1_500, seconds: 2)
        XCTAssertEqual(d, .init(rx: 2_000, tx: 1_000, plausible: true))
    }

    func testCounterResetReturnsNil() {
        XCTAssertNil(UsageMath.delta(prevRx: 5_000, prevTx: 0, rx: 10, tx: 0, seconds: 2))
    }

    func testOutlierAboveOneGbpsIsDiscarded() {
        let d = UsageMath.delta(prevRx: 0, prevTx: 0, rx: 1_000_000_000, tx: 0, seconds: 2)
        XCTAssertEqual(d, .init(rx: 0, tx: 0, plausible: false))
    }

    func testHugeCountersDoNotOverflow() {
        let d = UsageMath.delta(prevRx: 0, prevTx: 0, rx: .max, tx: .max, seconds: 2)
        XCTAssertEqual(d?.plausible, false)
    }

    func testHourBucket() {
        let date = Date(timeIntervalSince1970: 3600 * 10 + 1234)
        XCTAssertEqual(UsageMath.hourBucket(date), 36_000)
    }
}
