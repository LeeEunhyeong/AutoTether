import Foundation
import AppKit
import Observation
import Defaults

@MainActor @Observable
final class TetherEngine {
    enum Status: Equatable {
        case wifi(String?)
        case ethernet
        case tethered(String)
        case noInternet
        case offline
        case wifiOff
        case connecting(String)
        case returning(String)
    }

    private(set) var status: Status = .offline
    private(set) var snapshot = NetworkSnapshot()
    private(set) var internetOK = true
    private(set) var busy = false
    private(set) var currentTetherDevice: String?

    let hotspots: HotspotService

    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var stepping = false
    private var tick = 0
    private var offlineTicks = 0
    private var failedProbes = 0
    private var failedTetherProbes = 0
    private var tetheredTicks = 0
    private var consecutiveFailures = 0
    private var lastAttempt: Date?
    private var noReturnUntil: Date?
    private var manualTether = false
    private var warnedNoLocation = false
    private var warnedNoCandidates = false

    // Bumped to invalidate whatever operation is in flight.
    private var generation = 0
    private var currentToken = OpToken(auto: true)
    private var lastJoin: (ssid: String, bssid: String?)?

    init(hotspots: HotspotService) {
        self.hotspots = hotspots
    }

    var tetherDeviceName: String {
        if let currentTetherDevice { return currentTetherDevice }
        if snapshot.isUSBTether { return "USB 테더링" }
        return snapshot.ssid ?? "개인용 핫스팟"
    }

    #if DEBUG
    func overrideStatusForDemo(_ s: Status) { status = s }
    #endif

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            }
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
    }

    private func didWake() {
        log("잠자기에서 깨어남 — 네트워크 다시 확인")
        lastAttempt = nil
        consecutiveFailures = 0
        offlineTicks = 1
        failedProbes = 1
        tick = 2
    }

    func cancelPending(_ reason: String, autoOnly: Bool = false) {
        if autoOnly && !currentToken.auto { return }
        generation += 1
        currentToken.cancel()
        if busy { log("진행 중인 전환 취소 — \(reason)", .warning) }
    }

    func checkNow() async {
        lastAttempt = nil
        tick = 2
        await step()
    }

    private func makeToken(auto: Bool) -> OpToken {
        currentToken = OpToken(auto: auto)
        return currentToken
    }

    private func isCurrent(_ gen: Int, _ token: OpToken) -> Bool {
        gen == generation && !Task.isCancelled && token.isValid
    }

    // Read at each decision point so turning the WPA2 exception off takes effect mid-attempt.
    private func requiresSAE(_ name: String, _ token: OpToken) -> Bool {
        let wpa2Allowed = Defaults[.hotspotWPA3].first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value == false
        return token.auto && !wpa2Allowed
    }

    // MARK: - Periodic check

    private func step() async {
        guard !stepping else { return }
        stepping = true
        defer { stepping = false }

        refreshSnapshot()
        guard !busy else { return }
        tick += 1

        if snapshot.isTethered {
            await checkWhileTethered()
            updateStatus()
            return
        }
        tetheredTicks = 0
        failedTetherProbes = 0
        currentTetherDevice = nil
        manualTether = false

        // Wi-Fi turned off by the user: leave it alone.
        guard snapshot.wifiPowered || snapshot.hasLink else {
            internetOK = false
            updateStatus()
            return
        }

        guard snapshot.hasLink else {
            internetOK = false
            offlineTicks += 1
            updateStatus()
            if Defaults[.isEnabled], offlineTicks >= 2 {
                await failover(reason: "Wi-Fi 연결 끊김", force: false)
            }
            return
        }
        offlineTicks = 0

        if tick % 3 == 0 {
            await probeInternet()
        }
        updateStatus()
    }

    private func checkWhileTethered() async {
        offlineTicks = 0
        failedProbes = 0

        if tick % 6 == 0 {
            let gen = generation
            let ssid = snapshot.ssid
            let ok = await InternetProbe.check()
            let now = NetworkSnapshot.current()
            guard !busy, gen == generation, now.isTethered, now.ssid == ssid else { return }
            internetOK = ok
            failedTetherProbes = ok ? 0 : failedTetherProbes + 1
            if failedTetherProbes >= 3, Defaults[.isEnabled], !manualTether {
                failedTetherProbes = 0
                await failover(reason: "핫스팟에 인터넷 없음", force: true, excluding: currentTetherDevice ?? snapshot.ssid)
                return
            }
        }

        if Defaults[.isEnabled], Defaults[.returnToWiFi], !snapshot.isUSBTether, !manualTether {
            tetheredTicks += 1
            if tetheredTicks % 24 == 0 { await returnToWiFi(manual: false) }
        }
    }

    private func probeInternet() async {
        let gen = generation
        let link = snapshot.linkInterface
        let ssid = snapshot.ssid
        let ok = await InternetProbe.check()
        let now = NetworkSnapshot.current()
        // The network may have changed while the probe was running.
        guard !busy, gen == generation, now.linkInterface == link, now.ssid == ssid else { return }

        if ok != internetOK {
            log(ok ? "인터넷 연결 정상" : "네트워크는 연결됐지만 인터넷 없음", ok ? .info : .warning)
        }
        internetOK = ok
        if ok {
            failedProbes = 0
            consecutiveFailures = 0
            return
        }
        failedProbes += 1
        if Defaults[.isEnabled], Defaults[.leaveDeadWiFi], failedProbes >= 2, snapshot.isOnWiFi {
            await failover(reason: "Wi-Fi에 인터넷 없음 (30초)", force: true)
        }
    }

    private func refreshSnapshot() {
        KnownHotspots.names = Set(Defaults[.priority].map(\.name)).union(hotspots.devices.map(\.name))
        snapshot = NetworkSnapshot.current()
    }

    private func updateStatus() {
        guard !busy else { return }
        if snapshot.isTethered {
            status = internetOK ? .tethered(tetherDeviceName) : .noInternet
        } else if !snapshot.hasLink {
            status = snapshot.wifiPowered ? .offline : .wifiOff
        } else if !internetOK {
            status = .noInternet
        } else if snapshot.isOnWiFi {
            status = .wifi(snapshot.ssid)
        } else {
            status = .ethernet
        }
    }

    // MARK: - Failover

    func failover(reason: String, force: Bool, manual: Bool = false, auto: Bool = true, excluding: String? = nil) async {
        let cooldown: TimeInterval = consecutiveFailures >= 3 ? 300 : 30
        if !manual, let lastAttempt, Date().timeIntervalSince(lastAttempt) < cooldown { return }
        guard !busy else { return }

        let candidates = Defaults[.priority].filter { $0.enabled && $0.name != excluding }
        guard !candidates.isEmpty else {
            if !warnedNoCandidates {
                log("우선순위 목록에 활성화된 기기가 없음", .warning)
                warnedNoCandidates = true
            }
            lastAttempt = Date()
            return
        }
        warnedNoCandidates = false

        busy = true
        let gen = generation
        let token = makeToken(auto: auto)
        defer {
            busy = false
            lastAttempt = Date()
            refreshSnapshot()
            updateStatus()
        }
        log("\(reason) → 우선순위대로 테더링 시도 (\(candidates.map(\.name).joined(separator: " → ")))", .warning)

        for item in candidates {
            guard isCurrent(gen, token) else {
                log("전환 중단 (스위치 OFF 또는 Wi-Fi 꺼짐)")
                return
            }
            status = .connecting(item.name)
            if await connect(to: item.name, force: force, gen: gen, token: token) {
                guard isCurrent(gen, token) else {
                    if let wifi = snapshot.wifiInterface, let join = lastJoin,
                       dropLinkIfOurs(ssid: join.ssid, bssid: join.bssid, iface: wifi) {
                        log("연결 직후 전환이 취소되어 핫스팟 연결을 해제함", .warning)
                    }
                    return
                }
                consecutiveFailures = 0
                currentTetherDevice = item.name
                log("✅ \(item.name) 핫스팟으로 연결됨", .success)
                if Defaults[.notifyOnSwitch] { Notifier.post("핫스팟으로 전환됨", reason) }
                return
            }
            if !force && regularNetworkIsBack() {
                log("기존 네트워크가 복구되어 전환 중단")
                return
            }
        }

        guard gen == generation else { return }
        consecutiveFailures += 1
        log("연결 가능한 핫스팟을 찾지 못함 (연속 실패 \(consecutiveFailures)회)", .error)
        if Defaults[.notifyOnSwitch] && consecutiveFailures == 1 {
            Notifier.post("테더링 연결 실패", "주변에서 사용 가능한 핫스팟을 찾지 못했습니다.")
        }
    }

    private func regularNetworkIsBack() -> Bool {
        let now = NetworkSnapshot.current()
        return now.hasLink && !now.isTethered
    }

    private func connect(to name: String, force: Bool, gen: Int, token: OpToken) async -> Bool {
        lastJoin = nil
        guard let iface = snapshot.wifiInterface ?? NetworkSnapshot.current().wifiInterface else { return false }
        let wasTethered = NetworkSnapshot.current().isTethered

        if let device = hotspots.device(named: name) {
            switch await joinViaInstantHotspot(device, iface: iface, wasTethered: wasTethered,
                                               force: force, gen: gen, token: token) {
            case .connected: return true
            case .failed: return false
            case .tryFallback: break
            }
        } else {
            log("\(name) 블루투스 범위에 없음")
        }

        // networksetup can't choose the security type or BSSID, so it's only used when WPA3 isn't required.
        guard isCurrent(gen, token) else { return false }
        if requiresSAE(name, token) {
            log("'\(name)': 자동 연결은 WPA3 검증이 필요해 저장된 프로필 경로를 건너뜀")
            return false
        }
        guard await WiFiControl.preferredNetworks(interface: iface).contains(name) else {
            log("'\(name)'은 저장된 네트워크가 아니어서 직접 연결을 건너뜀")
            return false
        }
        guard isCurrent(gen, token) else { return false }
        log("저장된 프로필로 '\(name)' 연결 시도")
        await WiFiControl.joinSaved(ssid: name, interface: iface)
        let ok = await waitForTether(ssid: name, bssid: nil, iface: iface, wasTethered: wasTethered,
                                     requireSAE: false, gen: gen, token: token)
        if ok {
            lastJoin = (name, WiFiControl.currentBSSID(interface: iface))
            rememberConnection(name: name, ssid: name, iface: iface, manual: !token.auto)
        } else if !isCurrent(gen, token) {
            _ = dropLinkIfOurs(ssid: name, bssid: nil, iface: iface)
        }
        return ok
    }

    // Only drop a link we can identify as the one we just joined.
    @discardableResult
    private func dropLinkIfOurs(ssid: String, bssid: String?, iface: String) -> Bool {
        guard WiFiControl.isOnNetwork(ssid: ssid, bssid: bssid, interface: iface) else {
            log("현재 링크가 방금 연결한 핫스팟인지 확인할 수 없어 유지함", .warning)
            return false
        }
        WiFiControl.disassociate(interface: iface)
        return true
    }

    private enum JoinOutcome { case connected, failed, tryFallback }

    private func joinViaInstantHotspot(_ device: HotspotDevice, iface: String, wasTethered: Bool,
                                       force: Bool, gen: Int, token: OpToken) async -> JoinOutcome {
        let name = device.name
        log("\(name)에 핫스팟 켜기 요청 (배터리 \(device.battery)%)")
        let credentials: (ssid: String, password: String?)
        do {
            credentials = try await hotspots.enableHotspot(device, token: token)
        } catch is CancellationError {
            return .failed
        } catch {
            log("\(name) 핫스팟 켜기 실패: \(error.localizedDescription)", .warning)
            return .tryFallback
        }
        guard isCurrent(gen, token) else { return .failed }
        log("\(name) 핫스팟 켜짐")
        guard let password = credentials.password else {
            log("기기가 비밀번호를 주지 않음", .warning)
            return .tryFallback
        }
        try? await Task.sleep(for: .seconds(2))

        let ssid = credentials.ssid
        var triedBSSIDs = Set<String>()
        for attempt in 1...3 {
            guard isCurrent(gen, token) else { return .failed }
            let requireSAE = requiresSAE(name, token)
            let result = await WiFiControl.joinHotspot(
                ssid: ssid, password: password, interface: iface,
                preferredBSSIDs: Set(Defaults[.pinnedBSSIDs][ssid] ?? []), excludedBSSIDs: triedBSSIDs,
                requireWPA3: requireSAE, token: token)
            log("연결 시도 \(attempt)/3: \(result.message)", result.ok ? .info : .warning)
            if result.cancelled { return .failed }

            if result.ok, await waitForTether(ssid: ssid, bssid: result.bssid, iface: iface, wasTethered: wasTethered,
                                              requireSAE: requireSAE, gen: gen, token: token) {
                lastJoin = (ssid, result.bssid)
                rememberConnection(name: name, ssid: ssid, iface: iface, manual: !token.auto)
                return .connected
            }
            if result.ok && !isCurrent(gen, token) {
                if dropLinkIfOurs(ssid: ssid, bssid: result.bssid, iface: iface) {
                    log("연결 도중 취소되어 '\(name)' 링크를 해제함", .warning)
                }
                return .failed
            }
            if let bssid = result.bssid { triedBSSIDs.insert(bssid) }
            if !force && regularNetworkIsBack() { return .failed }
        }
        // We had real credentials from the device; don't fall back to the weaker saved-profile path.
        return .failed
    }

    private func waitForTether(ssid: String, bssid: String?, iface: String, wasTethered: Bool, requireSAE: Bool,
                               gen: Int, token: OpToken, seconds: Int = 10) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            guard isCurrent(gen, token) else { return false }
            let now = NetworkSnapshot.current()
            guard now.isTethered, now.tetherInterface == iface else { continue }

            if let current = now.ssid {
                guard current == ssid else { continue }
                if WiFiControl.isConnected(to: ssid, interface: iface, requireSAE: requireSAE) {
                    snapshot = now
                    return true
                }
                if let security = WiFiControl.currentSecurity(interface: iface), security != .unknown {
                    if dropLinkIfOurs(ssid: ssid, bssid: bssid, iface: iface) {
                        log("'\(ssid)'가 허용되지 않는 보안 방식(\(security.rawValue))으로 연결되어 끊음", .error)
                    }
                    return false
                }
                continue
            }

            // No SSID (no location permission): rely on the path signal and the negotiated security.
            guard let security = WiFiControl.currentSecurity(interface: iface), security != .unknown else { continue }
            guard SecurityPolicy.hotspotAssociationAllowed(security, requireSAE: requireSAE) else {
                if dropLinkIfOurs(ssid: ssid, bssid: bssid, iface: iface) {
                    log("허용되지 않는 보안 방식(\(security.rawValue))으로 협상되어 연결을 끊음", .error)
                }
                return false
            }
            if !wasTethered { snapshot = now; return true }
        }
        return false
    }

    private func rememberConnection(name: String, ssid: String, iface: String, manual: Bool) {
        guard WiFiControl.isConnected(to: ssid, interface: iface) else { return }
        if WiFiControl.currentSecurity(interface: iface) == .wpa3Personal {
            if Defaults[.hotspotWPA3][name] == nil {
                log("'\(name)' 핫스팟 WPA3(SAE) 확인")
                Defaults[.hotspotWPA3][name] = true
            }
        } else if manual {
            log("'\(name)'이 WPA2로 연결됨. 자동 연결은 WPA3만 허용 — 필요하면 '기기 우선순위'에서 WPA2 허용을 켜세요", .warning)
        }

        guard let bssid = WiFiControl.currentBSSID(interface: iface) else { return }
        var seen = Defaults[.pinnedBSSIDs][ssid] ?? []
        guard !seen.contains(bssid) else { return }
        seen.append(bssid)
        Defaults[.pinnedBSSIDs][ssid] = Array(seen.suffix(4))
    }

    // MARK: - Return to Wi-Fi

    func returnToWiFi(manual: Bool) async {
        if !manual, let noReturnUntil, noReturnUntil > Date() { return }
        guard !busy, let iface = snapshot.wifiInterface else { return }
        if !manual && !AppModel.shared.location.isAuthorized {
            if !warnedNoLocation {
                log("위치 권한이 없어 주변 Wi-Fi 이름을 확인할 수 없음 — 자동 복귀 비활성", .warning)
                warnedNoLocation = true
            }
            return
        }

        busy = true
        if manual { generation += 1 }
        let gen = generation
        let token = makeToken(auto: !manual)
        defer {
            busy = false
            refreshSnapshot()
            updateStatus()
        }

        let hotspotNames = Set(Defaults[.priority].map(\.name)).union(hotspots.devices.map(\.name))
        let candidates = await WiFiControl.secureKnownNetworksInRange(interface: iface, excluding: hotspotNames)
        guard let target = candidates.first else {
            if manual { log("범위 내 저장된 Wi-Fi를 찾지 못함", .warning) }
            return
        }
        guard isCurrent(gen, token), NetworkSnapshot.current().isTethered else { return }
        status = .returning(target)
        log("저장된 Wi-Fi '\(target)' 감지 → 복귀 시도")

        // The first networksetup join after a hotspot often fails, so retry the same network.
        // Never just disassociate and let macOS auto-join: it could pick a saved open network.
        var joined = false
        for attempt in 1...3 where !joined {
            guard isCurrent(gen, token) else { return }
            await WiFiControl.joinSaved(ssid: target, interface: iface)
            guard isCurrent(gen, token) else { return }
            joined = await waitForRegularWiFi(seconds: 10, gen: gen, token: token)
            if !joined && attempt < 3 { log("'\(target)' 복귀 재시도 \(attempt + 1)/3") }
        }

        guard isCurrent(gen, token) else { return }

        // macOS may pick the other band of the same router, so any vetted candidate is fine.
        func associationIsVetted() -> Bool {
            WiFiControl.currentSecurityIsStrong(interface: iface)
                && (NetworkSnapshot.current().ssid.map(candidates.contains) ?? true)
        }
        func onVettedNetwork() -> Bool {
            let now = NetworkSnapshot.current()
            return now.isOnWiFi && !now.isTethered && associationIsVetted()
        }
        if joined && !associationIsVetted() {
            let security = WiFiControl.currentSecurity(interface: iface)?.rawValue ?? -1
            log("복귀한 네트워크의 보안/이름이 기대와 달라 거부 (보안 방식 \(security))", .error)
            WiFiControl.disassociate(interface: iface)
        }
        let secure = joined && onVettedNetwork()

        var online = false
        if secure {
            // DHCP and routes are often not ready right after joining.
            for attempt in 0..<4 where !online {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                guard isCurrent(gen, token) else { return }
                guard onVettedNetwork() else { break }
                online = await InternetProbe.check() && onVettedNetwork()
            }
        }
        guard isCurrent(gen, token) else { return }

        if online {
            currentTetherDevice = nil
            manualTether = false
            internetOK = true
            log("✅ Wi-Fi '\(NetworkSnapshot.current().ssid ?? target)'로 복귀함", .success)
            if Defaults[.notifyOnSwitch] { Notifier.post("Wi-Fi로 복귀함", "저장된 Wi-Fi에 연결되었습니다.") }
            return
        }
        noReturnUntil = Date().addingTimeInterval(900)
        log("'\(target)' 복귀 실패 — 15분간 재시도 안 함, 핫스팟으로 다시 연결", .warning)
        busy = false
        await failover(reason: "Wi-Fi 복귀 실패", force: true, manual: true, auto: !manual)
    }

    private func waitForRegularWiFi(seconds: Int, gen: Int, token: OpToken) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            guard isCurrent(gen, token) else { return false }
            let now = NetworkSnapshot.current()
            let primary = now.primaryInterface ?? now.pathInterface
            if now.isOnWiFi && !now.isTethered && primary == now.wifiInterface {
                snapshot = now
                return true
            }
        }
        return false
    }

    // MARK: - Manual connect

    func connectNow(_ name: String) async {
        if busy {
            cancelPending("수동 연결 요청")
            for _ in 0..<30 where busy { try? await Task.sleep(for: .milliseconds(500)) }
            guard !busy else {
                log("이전 작업이 끝나지 않아 수동 연결을 시작하지 못함", .warning)
                return
            }
        }
        generation += 1
        let gen = generation
        let token = makeToken(auto: false)
        busy = true
        status = .connecting(name)
        log("수동 연결: \(name)")
        let ok = await connect(to: name, force: true, gen: gen, token: token)
        busy = false
        if ok {
            currentTetherDevice = name
            manualTether = true
            log("✅ \(name) 핫스팟으로 연결됨", .success)
        } else {
            log("\(name) 연결 실패", .error)
        }
        refreshSnapshot()
        updateStatus()
    }
}
