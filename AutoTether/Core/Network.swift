import Foundation
import CoreWLAN
import Defaults
import Network
import SystemConfiguration

// macOS marks Personal Hotspot paths as "expensive"; that is the signal used to detect tethering.
final class PathWatcher: @unchecked Sendable {
    static let shared = PathWatcher()

    struct State {
        var satisfied = false
        var expensive = false
        var physicalInterface: String?
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = State()

    var state: State { lock.withLock { current } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let physical = path.availableInterfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
            let state = State(satisfied: path.status == .satisfied && physical != nil,
                              expensive: path.isExpensive,
                              physicalInterface: physical?.name)
            self?.lock.withLock { self?.current = state }
        }
        monitor.start(queue: DispatchQueue(label: "AutoTether.path"))
    }
}

final class OpToken: @unchecked Sendable {
    let auto: Bool
    private let lock = NSLock()
    private var cancelled = false

    init(auto: Bool) { self.auto = auto }

    func cancel() { lock.withLock { cancelled = true } }

    var isValid: Bool {
        if lock.withLock({ cancelled }) { return false }
        if auto && !Defaults[.isEnabled] { return false }
        return CWWiFiClient.shared().interface()?.powerOn() ?? false
    }
}

enum AppleDeviceInterface {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func isAppleDevice(_ bsdName: String) -> Bool {
        if let cached = lock.withLock({ cache[bsdName] }) { return cached }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let name = interfaces
            .first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? ""
        let result = name.contains("iPhone") || name.contains("iPad")
        lock.withLock { cache[bsdName] = result }
        return result
    }
}

enum KnownHotspots {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: Set<String> = []

    static var names: Set<String> {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

struct NetworkSnapshot: Equatable {
    var primaryInterface: String?
    var addresses: [String: String] = [:]
    var wifiInterface: String?
    var wifiPowered = false
    var ssid: String?
    var pathSatisfied = false
    var pathExpensive = false
    var pathInterface: String?

    var tetherInterface: String? {
        TetherClassifier.tetherInterface(.init(
            addresses: addresses, primaryInterface: primaryInterface, pathInterface: pathInterface,
            pathSatisfied: pathSatisfied, pathExpensive: pathExpensive, wifiInterface: wifiInterface,
            linkInterface: linkInterface, isAppleDevice: AppleDeviceInterface.isAppleDevice))
    }

    var isTethered: Bool { hasLink && tetherInterface != nil }
    var isUSBTether: Bool { isTethered && tetherInterface != wifiInterface }
    var hasLink: Bool { !addresses.isEmpty || pathSatisfied }
    var isOnWiFi: Bool { linkInterface != nil && linkInterface == wifiInterface }

    var linkInterface: String? {
        if let p = primaryInterface, addresses[p] != nil { return p }
        if let p = pathInterface, pathSatisfied { return p }
        return addresses.keys.sorted().first
    }

    static func current() -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        if let store = SCDynamicStoreCreate(nil, "AutoTether" as CFString, nil, nil) {
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            snap.primaryInterface = global?["PrimaryInterface"] as? String

            let list = SCDynamicStoreCopyValue(store, "State:/Network/Interface" as CFString) as? [String: Any]
            for name in list?["Interfaces"] as? [String] ?? [] where name.hasPrefix("en") {
                let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/IPv4" as CFString) as? [String: Any]
                let addresses = ipv4?["Addresses"] as? [String] ?? []
                if let address = addresses.first(where: { !$0.hasPrefix("169.254.") }) {
                    snap.addresses[name] = address
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
        return snap
    }
}

enum InternetProbe {
    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let endpoints = [
        ("captive.apple.com", "/hotspot-detect.html"),
        ("www.apple.com", "/library/test/success.html"),
    ]

    static func check(timeout: TimeInterval = 5) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        for (host, path) in endpoints {
            guard let url = URL(string: "https://\(host)\(path)"),
                  let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200, http.url?.host == host, data.count < 4096
            else { continue }
            if String(decoding: data, as: UTF8.self).contains("<TITLE>Success</TITLE>") { return true }
        }
        return false
    }
}

enum WiFiControl {
    struct JoinResult {
        var ok: Bool
        var message: String
        var bssid: String?
        var cancelled = false
    }

    // Instant Hotspot broadcasts a hidden SSID, so it has to be found with a directed scan.
    static func joinHotspot(ssid: String, password: String, interface: String,
                            preferredBSSIDs: Set<String>, excludedBSSIDs: Set<String>,
                            requireWPA3: Bool, token: OpToken) async -> JoinResult {
        await Task.detached(priority: .userInitiated) {
            guard let wifi = CWWiFiClient.shared().interface(withName: interface) else {
                return JoinResult(ok: false, message: "Wi-Fi 인터페이스 없음")
            }
            guard !password.isEmpty else { return JoinResult(ok: false, message: "핫스팟 비밀번호를 받지 못함") }

            var found: CWNetwork?
            var selection = SecurityPolicy.Selection(accepted: [], rejectedSecurity: 0, rejectedNoWPA3: 0)
            for attempt in 0..<3 {
                guard token.isValid else { return JoinResult(ok: false, message: "취소됨", cancelled: true) }
                if let networks = try? wifi.scanForNetworks(withName: ssid, includeHidden: true) {
                    let scanned = networks
                        .filter { $0.ssid == ssid }
                        .map { (info: APInfo($0), network: $0) }
                        .filter { !excludedBSSIDs.contains($0.info.bssid ?? "") }
                    selection = SecurityPolicy.selectHotspotCandidates(scanned.map(\.info), requireWPA3: requireWPA3)
                    let best = SecurityPolicy.bestHotspot(selection.accepted, preferredBSSIDs: preferredBSSIDs)
                    found = scanned.first { $0.info == best }?.network
                }
                // A WPA2-only match may be a rogue AP; keep scanning in case the real WPA3 beacon shows up.
                if attempt == 2 { break }
                if let found, found.supportsSecurity(.wpa3Personal) { break }
                usleep(1_500_000)
            }

            guard let network = found else {
                if selection.rejectedNoWPA3 > 0 {
                    return JoinResult(ok: false, message: "WPA3를 지원하지 않는 같은 이름의 AP \(selection.rejectedNoWPA3)개를 거부함")
                }
                if selection.rejectedSecurity > 0 {
                    return JoinResult(ok: false, message: "같은 이름의 보안 방식이 다른 AP \(selection.rejectedSecurity)개를 거부함")
                }
                return JoinResult(ok: false, message: "핫스팟 신호를 찾지 못함")
            }
            guard token.isValid else { return JoinResult(ok: false, message: "취소됨", cancelled: true) }

            let bssid = network.bssid?.lowercased()
            do {
                try wifi.associate(to: network, password: password)
                // CoreWLAN can't force SAE on a transition-mode AP, so check what was negotiated.
                let security = wifi.security()
                if requireWPA3 && security != .wpa3Personal && security != .unknown {
                    wifi.disassociate()
                    return JoinResult(ok: false, message: "WPA3가 아닌 방식(\(security.rawValue))으로 협상되어 연결을 끊음", bssid: bssid)
                }
                return JoinResult(ok: true, message: "연결됨 (RSSI \(network.rssiValue))", bssid: bssid)
            } catch {
                return JoinResult(ok: false, message: error.localizedDescription, bssid: bssid)
            }
        }.value
    }

    static func currentSecurity(interface: String) -> CWSecurity? {
        CWWiFiClient.shared().interface(withName: interface)?.security()
    }

    static func currentBSSID(interface: String) -> String? {
        CWWiFiClient.shared().interface(withName: interface)?.bssid()?.lowercased()
    }

    static func isConnected(to ssid: String, interface: String, requireSAE: Bool = false) -> Bool {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface), wifi.ssid() == ssid else { return false }
        return SecurityPolicy.hotspotAssociationAllowed(wifi.security(), requireSAE: requireSAE)
    }

    // SSID and BSSID both read as nil without location access; then we can't tell and say no.
    static func isOnNetwork(ssid: String, bssid: String?, interface: String) -> Bool {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface) else { return false }
        let currentSSID = wifi.ssid()
        let currentBSSID = wifi.bssid()?.lowercased()
        if let currentSSID, currentSSID != ssid { return false }
        if let bssid, let currentBSSID, currentBSSID != bssid { return false }
        return currentSSID != nil || (bssid != nil && currentBSSID != nil)
    }

    static func disassociate(interface: String) {
        CWWiFiClient.shared().interface(withName: interface)?.disassociate()
    }

    // Joins with the keychain profile; the password never appears in process arguments.
    // The output is unreliable, so callers check the resulting network state instead.
    static func joinSaved(ssid: String, interface: String) async {
        _ = await Shell.run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid], timeout: 30)
    }

    static func currentSecurityIsStrong(interface: String) -> Bool {
        SecurityPolicy.associationIsStrong(currentSecurity(interface: interface))
    }

    static func preferredNetworks(interface: String) async -> [String] {
        let result = await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface])
        return result.output
            .split(separator: "\n")
            .filter { $0.hasPrefix("\t") }
            .map { String($0.dropFirst()) }
            .filter { !$0.isEmpty }
    }

    static func secureKnownNetworksInRange(interface: String, excluding: Set<String>, minRSSI: Int = -72) async -> [String] {
        let known = Set(await preferredNetworks(interface: interface).filter {
            !excluding.contains($0) && !$0.hasPrefix("DIRECT-")
        })
        guard !known.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            guard let wifi = CWWiFiClient.shared().interface(withName: interface),
                  let networks = try? wifi.scanForNetworks(withName: nil) else { return [] }
            return SecurityPolicy.returnCandidates(networks.map(APInfo.init), known: known, minRSSI: minRSSI)
        }.value
    }
}
