import Foundation
import SystemConfiguration
import CoreWLAN
import Network
import Defaults

/// NWPathMonitor 상시 실행. 개인용 핫스팟은 macOS가 'expensive' 경로로 표시함 (iOS 핫스팟 공식 신호).
final class PathWatcher: @unchecked Sendable {
    static let shared = PathWatcher()

    struct State {
        var satisfied = false
        var expensive = false
        var physicalInterface: String?
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _state = State()
    var state: State { lock.withLock { _state } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let phys = path.availableInterfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
            let st = State(satisfied: path.status == .satisfied && phys != nil,
                           expensive: path.isExpensive,
                           physicalInterface: phys?.name)
            self?.lock.withLock { self?._state = st }
        }
        monitor.start(queue: DispatchQueue(label: "AutoTether.path"))
    }
}

/// 진행 중인 전환 작업의 취소 신호. 백그라운드(스캔/연결 직전)에서도 확인 가능.
final class OpToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    /// 자동 작업이면 마스터 스위치 OFF 시 무효
    let auto: Bool
    init(auto: Bool) { self.auto = auto }
    func cancel() { lock.withLock { cancelled = true } }
    var isValid: Bool {
        if lock.withLock({ cancelled }) { return false }
        if auto && !Defaults[.isEnabled] { return false }
        return CWWiFiClient.shared().interface()?.powerOn() ?? false
    }
}

/// iPhone/iPad USB 테더링 인터페이스인지 (시스템이 붙인 인터페이스 이름으로 판별, 결과 캐시)
enum AppleDeviceInterface {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    static func isAppleDevice(_ bsd: String) -> Bool {
        if let v = lock.withLock({ cache[bsd] }) { return v }
        var result = false
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
                let name = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? ""
                result = name.contains("iPhone") || name.contains("iPad")
            }
        }
        lock.withLock { cache[bsd] = result }
        return result
    }
}

/// 핫스팟으로 알려진 SSID (우선순위 목록 + 주변에서 발견된 기기). 메인 액터에서 갱신.
enum KnownHotspots {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _names: Set<String> = []
    static var names: Set<String> {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }
}

/// 현재 네트워크 상태 스냅샷 (SCDynamicStore + CoreWLAN)
struct NetworkSnapshot: Equatable {
    var primaryInterface: String?
    /// IPv4 주소가 있는 물리 인터페이스(en*) 목록 → 주소
    var addresses: [String: String] = [:]
    var wifiInterface: String?
    var wifiPowered = false
    /// 위치 권한이 있을 때만 값이 있음
    var ssid: String?
    var pathSatisfied = false
    var pathExpensive = false
    var pathInterface: String?
    var ssidIsKnownHotspot = false

    static let empty = NetworkSnapshot()

    /// 테더링 판별:
    ///  1) 구형 iOS 핫스팟/USB: 172.20.10.x 주소
    ///  2) 최신 iOS 핫스팟: IPv6 전용 + CLAT(192.0.0.2) → macOS가 'expensive' 경로로 표시
    ///  3) 연결된 Wi-Fi SSID가 알려진 핫스팟 기기 이름
    ///  이름(SSID)·주소 대역 단독으로는 판정하지 않음. macOS가 iOS 핫스팟에 붙이는 'expensive' 경로 신호를 필수로 요구.
    ///  (같은 이름의 일반/가짜 AP나 172.20.10.x를 주는 공유기를 테더링으로 오인 → 잠자기 방지·사용량 오작동 방지)
    var tetherInterface: String? {
        TetherClassifier.tetherInterface(.init(
            addresses: addresses, primaryInterface: primaryInterface, pathInterface: pathInterface,
            pathSatisfied: pathSatisfied, pathExpensive: pathExpensive, wifiInterface: wifiInterface,
            linkInterface: linkInterface, isAppleDevice: AppleDeviceInterface.isAppleDevice))
    }
    var isTethered: Bool { hasLink && tetherInterface != nil }
    var isUSBTether: Bool { isTethered && tetherInterface != wifiInterface }

    /// 물리 인터페이스에 IP가 있거나 물리 경로가 살아 있으면 링크 있음 (VPN utun은 제외)
    var hasLink: Bool { !addresses.isEmpty || pathSatisfied }
    var linkInterface: String? {
        if let p = primaryInterface, addresses[p] != nil { return p }
        if let p = pathInterface, pathSatisfied { return p }   // IPv6 전용 네트워크
        return addresses.keys.sorted().first
    }
    var isOnWiFi: Bool { linkInterface != nil && linkInterface == wifiInterface }

    static func current() -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        if let store = SCDynamicStoreCreate(nil, "AutoTether" as CFString, nil, nil) {
            if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                snap.primaryInterface = global["PrimaryInterface"] as? String
            }
            if let list = SCDynamicStoreCopyValue(store, "State:/Network/Interface" as CFString) as? [String: Any],
               let names = list["Interfaces"] as? [String] {
                for name in names where name.hasPrefix("en") {
                    let key = "State:/Network/Interface/\(name)/IPv4" as CFString
                    if let v4 = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                       let addrs = v4["Addresses"] as? [String],
                       let first = addrs.first(where: { !$0.hasPrefix("169.254.") }) {
                        snap.addresses[name] = first
                    }
                }
            }
        }
        let wifi = CWWiFiClient.shared().interface()
        snap.wifiInterface = wifi?.interfaceName
        snap.wifiPowered = wifi?.powerOn() ?? false
        snap.ssid = wifi?.ssid()
        let path = PathWatcher.shared.state
        snap.pathSatisfied = path.satisfied
        snap.pathExpensive = path.expensive
        snap.pathInterface = path.physicalInterface
        if let ssid = snap.ssid { snap.ssidIsKnownHotspot = KnownHotspots.names.contains(ssid) }
        return snap
    }
}

enum InternetProbe {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }   // 캡티브 포털 리다이렉트 거부
    }

    /// 실제 인터넷 확인 (캡티브 포털/죽은 Wi-Fi 감지).
    /// HTTPS(인증서 검증) + 리다이렉트 거부 + 상태 200 + 최종 호스트 + 정확한 본문으로 판정.
    static func check(timeout: TimeInterval = 5) async -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.connectionProxyDictionary = [:]
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // 두 엔드포인트 중 하나라도 정상이면 인터넷 있음 (단일 도메인 차단으로 불필요한 전환 유도 방지)
        for (host, path) in [("captive.apple.com", "/hotspot-detect.html"), ("www.apple.com", "/library/test/success.html")] {
            guard let url = URL(string: "https://\(host)\(path)") else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.host == host, data.count < 4096 else { continue }
                if String(decoding: data, as: UTF8.self).contains("<TITLE>Success</TITLE>") { return true }
            } catch {
                continue
            }
        }
        return false
    }
}

enum WiFiControl {
    // 판단 로직은 Policy.swift(SecurityPolicy)에 있음 — 여기는 CoreWLAN 객체를 값으로 옮기는 얇은 래퍼
    nonisolated static func isPersonalWPA(_ net: CWNetwork) -> Bool { SecurityPolicy.isPersonalWPA(APInfo(net)) }
    nonisolated static func supportsWPA3(_ n: CWNetwork) -> Bool { SecurityPolicy.supportsWPA3(APInfo(n)) }

    /// Instant Hotspot은 SSID를 숨김으로 송출 → 이름 지정(directed) 스캔 후 CoreWLAN으로 연결.
    /// Evil Twin 방지:
    ///  - SSID 정확히 일치 + WPA2/WPA3 개인용만(개방형/WEP/OWE/엔터프라이즈 광고 시 거부) + 기기에서 받은 비밀번호 필수
    ///  - requireWPA3: 이전에 WPA3로 연결된 핫스팟이면 WPA3 미지원 AP 거부
    ///    → WPA2 전용 가짜 AP가 실제 비밀번호의 4-way 핸드셰이크를 받아 오프라인 크래킹하는 공격 차단
    ///    (SAE는 비밀번호를 모르는 상대에게 오프라인 공격 자료를 주지 않음)
    ///  - 우선순위: 최근 검증된 BSSID > WPA3 지원 > 신호 세기 (BSSID는 iOS가 주기적으로 바꾸므로 힌트로만 사용)
    static func joinHotspot(ssid: String, password: String, interface: String,
                            preferredBSSIDs: Set<String>, excludedBSSIDs: Set<String> = [],
                            requireWPA3: Bool, token: OpToken) async -> (ok: Bool, message: String, bssid: String?) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String, String?) in
            guard let wifi = CWWiFiClient.shared().interface(withName: interface) else { return (false, "Wi-Fi 인터페이스 없음", nil) }
            guard !password.isEmpty else { return (false, "핫스팟 비밀번호를 받지 못함", nil) }
            var found: CWNetwork?
            var rejectedSecurity = 0
            var rejectedNoWPA3 = 0
            for i in 0..<3 {
                if let nets = try? wifi.scanForNetworks(withName: ssid, includeHidden: true) {
                    let fresh = nets.filter { $0.ssid == ssid && !($0.bssid.map { excludedBSSIDs.contains($0.lowercased()) } ?? false) }
                    let infos = fresh.map { (APInfo($0), $0) }
                    let r = SecurityPolicy.selectHotspotCandidates(infos.map(\.0), requireWPA3: requireWPA3)
                    rejectedSecurity = r.rejectedSecurity
                    rejectedNoWPA3 = r.rejectedNoWPA3
                    let best = SecurityPolicy.bestHotspot(r.accepted, preferredBSSIDs: preferredBSSIDs)
                    found = best.flatMap { b in infos.first { $0.0 == b }?.1 }
                }
                // WPA3 후보면 즉시 사용. WPA2만 보이면 진짜 핫스팟(WPA3) 비콘이 늦게 올라올 수 있으니 끝까지 스캔.
                if let f = found, supportsWPA3(f) || i == 2 { break }
                Thread.sleep(forTimeInterval: 1.5)
            }
            guard let net = found else {
                if rejectedNoWPA3 > 0 { return (false, "WPA3를 지원하지 않는 같은 이름의 AP \(rejectedNoWPA3)개를 거부함 (다운그레이드 공격 의심 — 기기 설정을 바꿨다면 수동 연결)", nil) }
                if rejectedSecurity > 0 { return (false, "같은 이름의 보안 방식이 다른 AP \(rejectedSecurity)개를 거부함 (Evil Twin 의심)", nil) }
                return (false, "핫스팟 신호를 찾지 못함", nil)
            }
            guard token.isValid else { return (false, "취소됨", nil) }   // 스캔 중 스위치 OFF/Wi-Fi 꺼짐
            let bssid = net.bssid?.lowercased()
            do {
                try wifi.associate(to: net, password: password)
                return (true, "연결됨 (RSSI \(net.rssiValue))", bssid)
            } catch {
                return (false, error.localizedDescription, bssid)
            }
        }.value
    }

    /// 후보 선별 (순수 함수 → 진단/테스트에서 연결 없이 검증 가능)
    nonisolated static func selectHotspotCandidates(_ named: [CWNetwork], requireWPA3: Bool)
        -> (accepted: [CWNetwork], rejectedSecurity: Int, rejectedNoWPA3: Int) {
        let r = SecurityPolicy.selectHotspotCandidates(named.map(APInfo.init), requireWPA3: requireWPA3)
        let acceptedSet = Set(r.accepted)
        return (named.filter { acceptedSet.contains(APInfo($0)) }, r.rejectedSecurity, r.rejectedNoWPA3)
    }

    static func currentSecurity(interface: String) -> CWSecurity? {
        CWWiFiClient.shared().interface(withName: interface)?.security()
    }

    static func currentBSSID(interface: String) -> String? {
        CWWiFiClient.shared().interface(withName: interface)?.bssid()?.lowercased()
    }

    /// 현재 연결이 기대한 SSID + 허용 보안인지 (연결 후 확인). requireSAE면 실제 협상이 WPA3-Personal이어야 함.
    static func isConnected(to ssid: String, interface: String, requireSAE: Bool = false) -> Bool {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface) else { return false }
        guard wifi.ssid() == ssid else { return false }
        return SecurityPolicy.hotspotAssociationAllowed(wifi.security(), requireSAE: requireSAE)
    }

    static func disassociate(interface: String) {
        CWWiFiClient.shared().interface(withName: interface)?.disassociate()
    }

    /// 저장된(키체인) 프로필로 연결. 비밀번호는 절대 인자로 넘기지 않음(ps 노출 방지).
    /// macOS가 저장된 프로필의 보안 방식을 강제하므로 동명 개방형 AP로 다운그레이드되지 않음.
    /// 출력은 신뢰할 수 없으므로 호출 측에서 실제 상태로 판단할 것.
    static func joinSaved(ssid: String, interface: String) async -> Shell.Result {
        await Shell.run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid], timeout: 30)
    }

    nonisolated static func isSecureForReturn(_ n: CWNetwork) -> Bool { SecurityPolicy.isSecureForReturn(APInfo(n)) }

    /// 현재 연결된 보안 방식이 강한지 (연결 후 확인)
    static func currentSecurityIsStrong(interface: String) -> Bool {
        SecurityPolicy.associationIsStrong(currentSecurity(interface: interface))
    }

    static func preferredNetworks(interface: String) async -> [String] {
        let r = await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface])
        return r.output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("\t") }
            .map { String($0.dropFirst()) }
            .filter { !$0.isEmpty }
    }

    /// 범위 내에 있는 저장된(핫스팟이 아닌) 안전한 Wi-Fi 목록 (신호 강한 순). 위치 권한 필요.
    static func secureKnownNetworksInRange(interface: String, excluding: Set<String>, minRSSI: Int = -72) async -> [String] {
        let preferred = await preferredNetworks(interface: interface)
        let known = Set(preferred.filter { name in
            !excluding.contains(name) && !name.hasPrefix("DIRECT-")   // 이름 접두어(iPhone/iPad)로는 거르지 않음 — 일반 Wi-Fi일 수 있음
        })
        guard !known.isEmpty else { return [] }
        return await Task.detached(priority: .utility) { () -> [String] in
            guard let wifi = CWWiFiClient.shared().interface(withName: interface),
                  let networks = try? wifi.scanForNetworks(withName: nil) else { return [] }
            return SecurityPolicy.returnCandidates(networks.map(APInfo.init), known: known, minRSSI: minRSSI)
        }.value
    }
}
