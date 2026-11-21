import Foundation
import AppKit
import Observation
import Defaults

/// 자동 테더링 엔진: Wi-Fi가 끊기면 우선순위대로 핫스팟에 연결하고, 저장된 Wi-Fi가 돌아오면 복귀
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
    private(set) var snapshot = NetworkSnapshot.empty
    private(set) var internetOK = true
    private(set) var busy = false
    private(set) var currentTetherDevice: String?
    private(set) var lastSwitch: Date?

    let hotspots: HotspotService
    var onStateChange: (() -> Void)?

    private var loop: Task<Void, Never>?
    private var tick = 0
    private var downTicks = 0
    private var badProbes = 0
    private var tetherTicks = 0
    private var consecutiveFails = 0
    private var lastAttempt: Date?
    private var noReturnUntil: Date?
    private var warnedNoLocation = false
    private var warnedNoCandidates = false
    private var manualTether = false
    /// 진행 중 작업 무효화용 세대 번호 (일시 중지·Wi-Fi 끄기·새 수동 명령 시 증가)
    private var generation = 0
    /// 진행 중 작업의 취소 신호 (백그라운드 스캔/연결 직전에도 확인)
    private var currentToken = OpToken(auto: true)
    private var wakeObserver: NSObjectProtocol?
    private var stepping = false
    private var tetherBadProbes = 0

    init(hotspots: HotspotService) {
        self.hotspots = hotspots
    }

    var tetherDeviceName: String {
        if let d = currentTetherDevice { return d }
        if snapshot.isUSBTether { return "USB 테더링" }
        if let s = snapshot.ssid { return s }
        return "개인용 핫스팟"
    }

    #if DEBUG
    /// 스크린샷 전용: 엔진을 돌리지 않고 표시 상태만 지정
    func overrideStatusForDemo(_ s: Status) { status = s }
    #endif

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))   // 타이머 병합 허용 → CPU 깨우기 감소
            }
        }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                log("잠자기에서 깨어남 — 네트워크 다시 확인")
                self.lastAttempt = nil
                self.consecutiveFails = 0
                self.downTicks = 1
                self.badProbes = 1
                self.tick = 2
            }
        }
    }

    /// 진행 중인 전환 작업을 취소 (마스터 스위치 OFF 등)
    /// - autoOnly: true면 자동 작업만 취소 (마스터 스위치 OFF가 사용자의 수동 연결을 끊지 않도록)
    func cancelPending(_ why: String, autoOnly: Bool = false) {
        if autoOnly && !currentToken.auto { return }
        generation += 1
        currentToken.cancel()
        if busy { log("진행 중인 전환 취소 — \(why)", .warning) }
    }

    private func newToken(auto: Bool) -> OpToken {
        let t = OpToken(auto: auto)
        currentToken = t
        return t
    }

    /// 작업이 계속 진행돼도 되는지: 세대·토큰 유효, 자동 작업이면 마스터 스위치 ON, Wi-Fi 전원 ON
    private func alive(_ gen: Int, _ token: OpToken) -> Bool {
        gen == generation && !Task.isCancelled && token.isValid
    }

    /// 자동 연결의 최소 보안 정책: 기본은 WPA3(SAE) 필수.
    /// 사용자가 수동 연결로 WPA2를 승인한 기기(학습값 false)만 예외.
    private func autoRequiresWPA3(name: String, ssid: String) -> Bool {
        // WPA2 자동 연결 허용은 설정 화면의 기기별 명시적 동의(false)로만. 기기 이름 기준(대소문자 무시).
        let d = Defaults[.hotspotWPA3]
        return d.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value != false
    }

    // MARK: 주기 점검 (5초)

    private func step() async {
        guard !stepping else { return }   // 주기 루프와 '지금 확인'의 중복 실행 방지
        stepping = true
        defer { stepping = false }
        refreshSnapshot()
        guard !busy else { return }
        tick += 1

        if snapshot.isTethered {
            downTicks = 0; badProbes = 0
            if tick % 6 == 0 {
                let gen = generation, ssid = snapshot.ssid
                let ok = await InternetProbe.check()
                let now = NetworkSnapshot.current()
                guard !busy, gen == generation, now.isTethered, now.ssid == ssid else { return }
                internetOK = ok
                tetherBadProbes = internetOK ? 0 : tetherBadProbes + 1
                // 핫스팟인데 90초간 인터넷 없음 → 다음 우선순위 기기로
                if tetherBadProbes >= 3, Defaults[.isEnabled], !manualTether {
                    tetherBadProbes = 0
                    await failover(reason: "핫스팟에 인터넷 없음", force: true, excluding: currentTetherDevice ?? snapshot.ssid)
                    refreshStatus()
                    return
                }
            }
            if Defaults[.isEnabled], Defaults[.returnToWiFi], !snapshot.isUSBTether, !manualTether {
                tetherTicks += 1
                if tetherTicks % 24 == 0 { await returnToWiFi(manual: false) }   // 2분마다
            }
            refreshStatus()
            return
        }
        tetherTicks = 0
        tetherBadProbes = 0
        currentTetherDevice = nil
        manualTether = false

        guard snapshot.wifiPowered || snapshot.hasLink else {
            internetOK = false
            refreshStatus()
            return   // 사용자가 Wi-Fi를 끈 경우 존중
        }

        if !snapshot.hasLink {
            internetOK = false
            downTicks += 1
            refreshStatus()
            if Defaults[.isEnabled], downTicks >= 2 {   // 약 10초간 연결 없음
                await failover(reason: "Wi-Fi 연결 끊김", force: false)
            }
            return
        }
        downTicks = 0

        if tick % 3 == 0 {   // 15초마다 실제 인터넷 확인
            let gen = generation, link = snapshot.linkInterface, ssid = snapshot.ssid
            let ok = await InternetProbe.check()
            let now = NetworkSnapshot.current()
            // 프로브 도중 전환 작업이 시작됐거나 네트워크가 바뀌었다면 이전 네트워크의 결과는 버림
            guard !busy, gen == generation, now.linkInterface == link, now.ssid == ssid else { return }
            if ok != internetOK { log(ok ? "인터넷 연결 정상" : "네트워크는 연결됐지만 인터넷 없음", ok ? .info : .warning) }
            internetOK = ok
            if ok { badProbes = 0; consecutiveFails = 0 }
            else {
                badProbes += 1
                if Defaults[.isEnabled], Defaults[.leaveDeadWiFi], badProbes >= 2, snapshot.isOnWiFi {
                    await failover(reason: "Wi-Fi에 인터넷 없음 (30초)", force: true)
                }
            }
        }
        refreshStatus()
    }

    private func refreshSnapshot() {
        KnownHotspots.names = Set(Defaults[.priority].map(\.name)).union(hotspots.devices.map(\.name))
        let new = NetworkSnapshot.current()
        if new != snapshot {
            snapshot = new
            onStateChange?()
        }
    }

    private func refreshStatus() {
        guard !busy else { return }
        let s: Status
        if snapshot.isTethered { s = internetOK ? .tethered(tetherDeviceName) : .noInternet }
        else if !snapshot.hasLink { s = snapshot.wifiPowered ? .offline : .wifiOff }
        else if !internetOK { s = .noInternet }
        else if snapshot.isOnWiFi { s = .wifi(snapshot.ssid) }
        else { s = .ethernet }
        if s != status { status = s; onStateChange?() }
    }

    private func setStatus(_ s: Status) {
        status = s
        onStateChange?()
    }

    // MARK: 장애 조치

    /// 우선순위 목록 순서대로 핫스팟 연결 시도
    /// - auto: 자동 작업이면 마스터 스위치가 꺼지는 즉시 중단
    func failover(reason: String, force: Bool, manual: Bool = false, auto: Bool = true, excluding: String? = nil) async {
        let cooldown: TimeInterval = consecutiveFails >= 3 ? 300 : 30
        if !manual, let last = lastAttempt, Date().timeIntervalSince(last) < cooldown { return }
        guard !busy else { return }

        let candidates = Defaults[.priority].filter { $0.enabled && $0.name != excluding }
        guard !candidates.isEmpty else {
            if !warnedNoCandidates { log("우선순위 목록에 활성화된 기기가 없음", .warning); warnedNoCandidates = true }
            lastAttempt = Date()
            return
        }
        warnedNoCandidates = false

        busy = true
        let gen = generation
        let token = newToken(auto: auto)
        defer {
            busy = false
            lastAttempt = Date()   // 쿨다운은 시도 '완료' 시점부터
            refreshSnapshot()
            refreshStatus()
        }
        log("\(reason) → 우선순위대로 테더링 시도 (\(candidates.map(\.name).joined(separator: " → ")))", .warning)

        for item in candidates {
            guard alive(gen, token) else { log("전환 중단 (스위치 OFF 또는 Wi-Fi 꺼짐)"); return }
            setStatus(.connecting(item.name))
            if await connect(to: item.name, force: force, gen: gen, token: token) {
                guard alive(gen, token) else {
                    // 연결이 끝나는 순간 취소됐다면 결과를 반영하지 않고 연결도 정리 (사용자의 OFF 의도 존중)
                    if let w = snapshot.wifiInterface { WiFiControl.disassociate(interface: w) }
                    log("연결 직후 전환이 취소되어 핫스팟 연결을 해제함", .warning)
                    return
                }
                consecutiveFails = 0
                lastSwitch = Date()
                currentTetherDevice = item.name
                log("✅ \(item.name) 핫스팟으로 연결됨", .success)
                if Defaults[.notifyOnSwitch] {
                    Notifier.post("핫스팟으로 전환됨", reason)
                }
                return
            }
            if !force {
                let s = NetworkSnapshot.current()
                if s.hasLink && !s.isTethered {
                    log("기존 네트워크가 복구되어 전환 중단")
                    return
                }
            }
        }
        guard gen == generation else { return }
        consecutiveFails += 1
        log("연결 가능한 핫스팟을 찾지 못함 (연속 실패 \(consecutiveFails)회)", .error)
        if Defaults[.notifyOnSwitch] && consecutiveFails == 1 {
            Notifier.post("테더링 연결 실패", "주변에서 사용 가능한 핫스팟을 찾지 못했습니다.")
        }
    }

    private func connect(to name: String, force: Bool, gen: Int, token: OpToken) async -> Bool {
        guard let iface = snapshot.wifiInterface ?? NetworkSnapshot.current().wifiInterface else { return false }
        let auto = token.auto
        let wasTethered = NetworkSnapshot.current().isTethered

        if let device = hotspots.device(named: name) {
            log("\(name)에 핫스팟 켜기 요청 (배터리 \(device.battery)%)")
            do {
                let r = try await hotspots.enableHotspot(device, token: token)
                guard alive(gen, token) else { return false }
                log("\(name) 핫스팟 켜짐")
                try? await Task.sleep(for: .seconds(2))   // 기기 Wi-Fi가 올라올 시간
                let requireSAE = auto && autoRequiresWPA3(name: name, ssid: r.ssid)   // 수동 연결은 사용자 판단 존중
                var failedBSSIDs = Set<String>()
                for attempt in 1...3 {
                    guard alive(gen, token) else { return false }
                    guard let password = r.password else {
                        log("기기가 비밀번호를 주지 않음", .warning)
                        break
                    }
                    let preferred = Set(Defaults[.pinnedBSSIDs][r.ssid] ?? [])
                    let j = await WiFiControl.joinHotspot(ssid: r.ssid, password: password, interface: iface,
                                                          preferredBSSIDs: preferred, excludedBSSIDs: failedBSSIDs,
                                                          requireWPA3: requireSAE, token: token)
                    log("연결 시도 \(attempt)/3: \(j.message)", j.ok ? .info : .warning)
                    defer { if let b = j.bssid { failedBSSIDs.insert(b) } }   // 실패하면 다음 시도에서 같은 AP 제외
                    if j.ok, await waitForTether(ssid: r.ssid, iface: iface, wasTethered: wasTethered,
                                                 requireSAE: requireSAE, gen: gen, token: token, seconds: 10) {
                        learnSecurity(name: name, ssid: r.ssid, iface: iface, manual: !auto)
                        return true
                    }
                    if j.message == "취소됨" { return false }
                    if j.ok && !alive(gen, token) {
                        // association은 끝났는데 그 사이 취소됨 → 이 작업이 만든 링크만 정리
                        if WiFiControl.isConnected(to: r.ssid, interface: iface) { WiFiControl.disassociate(interface: iface) }
                        log("연결 도중 취소되어 '\(name)' 링크를 해제함", .warning)
                        return false
                    }
                    if !force {
                        let s = NetworkSnapshot.current()
                        if s.hasLink && !s.isTethered { return false }
                    }
                }
                // 기기에서 비밀번호를 받은 경우엔 networksetup 대체 경로로 내려가지 않음 (검증된 경로만 사용)
                if r.password != nil { return false }
            } catch is CancellationError {
                return false
            } catch {
                log("\(name) 핫스팟 켜기 실패: \(error.localizedDescription)", .warning)
            }
        } else {
            log("\(name) 블루투스 범위에 없음")
        }

        // 대체 경로: macOS에 저장된 프로필로만. networksetup은 AP의 보안 방식·BSSID를 고를 수 없으므로
        // 자동 연결에서 WPA3가 요구되는(기본) 기기는 이 경로를 쓰지 않음 → 다운그레이드 공격 표면 제거
        guard alive(gen, token) else { return false }
        if auto && autoRequiresWPA3(name: name, ssid: name) {
            log("'\(name)': 자동 연결은 WPA3 검증이 필요해 저장된 프로필 경로를 건너뜀")
            return false
        }
        let saved = await WiFiControl.preferredNetworks(interface: iface)
        guard saved.contains(name) else {
            log("'\(name)'은 저장된 네트워크가 아니어서 직접 연결을 건너뜀")
            return false
        }
        guard alive(gen, token) else { return false }
        log("저장된 프로필로 '\(name)' 연결 시도")
        _ = await WiFiControl.joinSaved(ssid: name, interface: iface)   // 출력은 신뢰 불가 → 상태로 판단
        let ok = await waitForTether(ssid: name, iface: iface, wasTethered: wasTethered,
                                     requireSAE: false, gen: gen, token: token, seconds: 10)
        if ok { learnSecurity(name: name, ssid: name, iface: iface, manual: !auto) }
        return ok
    }

    /// 요청한 핫스팟에 실제로 연결됐는지 확인.
    /// SSID를 읽을 수 있으면 SSID + 보안(requireSAE면 실제 WPA3 협상)까지 일치해야 성공.
    /// SAE가 요구됐는데 WPA2로 협상됐다면 즉시 끊음.
    private func waitForTether(ssid: String, iface: String, wasTethered: Bool, requireSAE: Bool,
                               gen: Int, token: OpToken, seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            guard alive(gen, token) else { return false }
            let s = NetworkSnapshot.current()
            guard s.isTethered, s.tetherInterface == iface else { continue }
            if s.ssid != nil {
                guard s.ssid == ssid else { continue }   // 다른 핫스팟/네트워크
                if WiFiControl.isConnected(to: ssid, interface: iface, requireSAE: requireSAE) { snapshot = s; return true }
                if requireSAE, WiFiControl.isConnected(to: ssid, interface: iface) {
                    WiFiControl.disassociate(interface: iface)
                    log("'\(ssid)'가 WPA3가 아닌 방식으로 협상되어 연결을 끊음 (다운그레이드 의심)", .error)
                    return false
                }
                continue
            }
            // SSID를 읽을 수 없음(위치 권한 없음): 이전에 테더링 중이 아니었고 SAE가 요구되지 않을 때만 경로 신호로 인정
            if !wasTethered && !requireSAE { snapshot = s; return true }
            if requireSAE, let sec = WiFiControl.currentSecurity(interface: iface) {
                if sec == .wpa3Personal { if !wasTethered { snapshot = s; return true } }
                else if sec != .none {
                    WiFiControl.disassociate(interface: iface)
                    log("WPA3가 아닌 방식(\(sec.rawValue))으로 협상되어 연결을 끊음 (SSID 확인 불가 상태)", .error)
                    return false
                }
            }
        }
        return false
    }

    /// 검증된 연결의 보안 능력과 BSSID(선호 힌트)를 기억.
    /// - WPA3로 협상되면 true 기록 (자동 연결 기본값도 WPA3 필수)
    /// - 사용자가 '수동'으로 연결했는데 WPA2였다면 false 기록 = 이 기기의 WPA2 자동 연결을 사용자가 승인한 것으로 간주
    private func learnSecurity(name: String, ssid: String, iface: String, manual: Bool) {
        guard WiFiControl.isConnected(to: ssid, interface: iface) else { return }
        let sae = WiFiControl.currentSecurity(interface: iface) == .wpa3Personal
        if sae {
            if Defaults[.hotspotWPA3][name] == nil { log("'\(name)' 핫스팟 WPA3(SAE) 확인") }
            if Defaults[.hotspotWPA3][name] != false { Defaults[.hotspotWPA3][name] = true }
        } else if manual {
            // 수동 연결 결과로 정책을 낮추지 않음 — WPA2 허용은 설정에서 기기별로 명시적으로 켜야 함
            log("'\(name)'이 WPA2로 연결됨. 자동 연결은 WPA3만 허용 — 필요하면 '기기 우선순위'에서 WPA2 허용을 켜세요", .warning)
        }
        guard let bssid = WiFiControl.currentBSSID(interface: iface) else { return }
        var pins = Defaults[.pinnedBSSIDs]
        var list = pins[ssid] ?? []
        guard !list.contains(bssid) else { return }
        list.append(bssid)
        pins[ssid] = Array(list.suffix(4))
        Defaults[.pinnedBSSIDs] = pins
    }

    /// 일반 Wi-Fi(핫스팟 아님)로 실제 복귀했는지. 유선/VPN 등 다른 인터페이스 링크는 인정하지 않음.
    private func waitForRegularNetwork(seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            let s = NetworkSnapshot.current()
            let primary = s.primaryInterface ?? s.pathInterface   // IPv6 전용 Wi-Fi면 IPv4 기본 경로가 없음
            if s.isOnWiFi && !s.isTethered && primary == s.wifiInterface { snapshot = s; return true }
        }
        return false
    }

    // MARK: Wi-Fi 복귀

    func returnToWiFi(manual: Bool) async {
        if !manual, let until = noReturnUntil, until > Date() { return }
        guard !busy, let iface = snapshot.wifiInterface else { return }
        if !manual, !AppModel.shared.location.isAuthorized {
            if !warnedNoLocation {
                log("위치 권한이 없어 주변 Wi-Fi 이름을 확인할 수 없음 — 자동 복귀 비활성", .warning)
                warnedNoLocation = true
            }
            return
        }
        busy = true   // 스캔 전에 선점 → 수동 조작과 경합 방지
        if manual { generation += 1 }
        let gen = generation
        let token = newToken(auto: !manual)
        defer {
            busy = false
            refreshSnapshot()
            refreshStatus()
        }
        let exclude = Set(Defaults[.priority].map(\.name)).union(hotspots.devices.map(\.name))
        let approved = await WiFiControl.secureKnownNetworksInRange(interface: iface, excluding: exclude)
        guard let target = approved.first else {
            if manual { log("범위 내 저장된 Wi-Fi를 찾지 못함", .warning) }
            return
        }
        guard alive(gen, token), NetworkSnapshot.current().isTethered else { return }
        setStatus(.returning(target))
        log("저장된 Wi-Fi '\(target)' 감지 → 복귀 시도")
        // 지정한 저장 Wi-Fi로만 재시도 (핫스팟에서 넘어갈 때 networksetup이 간헐적으로 실패함 — 실측).
        // 연결을 끊고 macOS 자동 연결에 맡기는 폴백은 쓰지 않음: 저장된 개방형 Wi-Fi의 가짜 AP로 붙을 수 있음
        var back = false
        for attempt in 1...3 where !back {
            guard alive(gen, token) else { return }
            _ = await WiFiControl.joinSaved(ssid: target, interface: iface)   // 출력은 신뢰 불가 → 상태로 판단
            guard alive(gen, token) else { return }
            back = await waitForRegularNetwork(seconds: 10)
            if !back && attempt < 3 { log("'\(target)' 복귀 재시도 \(attempt + 1)/3") }
        }
        let cur = NetworkSnapshot.current()
        // 같은 공유기의 2.4/5GHz처럼 macOS가 다른 저장 네트워크를 고를 수 있음 → 검증된 후보 목록 안이면 인정 (실측)
        let secure = back && WiFiControl.currentSecurityIsStrong(interface: iface) && (cur.ssid == nil || approved.contains(cur.ssid!))
        if back && !secure {
            log("복귀한 네트워크의 보안/이름이 기대와 달라 거부 (보안 방식 \(WiFiControl.currentSecurity(interface: iface)?.rawValue ?? -1))", .error)
            WiFiControl.disassociate(interface: iface)
        }
        // 연결 직후엔 주소·경로 설정이 덜 끝나 첫 검사가 실패할 수 있음(실측) → 최대 4회, 약 12초 동안 확인
        var ok = false
        if secure {
            for i in 0..<4 where !ok {
                if i > 0 { try? await Task.sleep(for: .seconds(3)) }
                guard gen == generation else { return }
                let s = NetworkSnapshot.current()
                guard s.isOnWiFi && !s.isTethered else { break }
                ok = await InternetProbe.check()
            }
        }
        guard gen == generation else { return }   // 검사 도중 다른 작업이 시작됨 → 결과 반영 안 함
        if ok {
            let actual = NetworkSnapshot.current().ssid ?? target
            currentTetherDevice = nil
            manualTether = false
            internetOK = true
            lastSwitch = Date()
            log("✅ Wi-Fi '\(actual)'로 복귀함", .success)
            if Defaults[.notifyOnSwitch] { Notifier.post("Wi-Fi로 복귀함", "저장된 Wi-Fi에 연결되었습니다.") }
        } else {
            noReturnUntil = Date().addingTimeInterval(900)
            guard gen == generation else { return }
            log("'\(target)' 복귀 실패 — 15분간 재시도 안 함, 핫스팟으로 다시 연결", .warning)
            busy = false
            // 복귀 시도로 연결을 끊은 것이므로 쿨다운 없이 즉시 복구 (자동 복귀였다면 스위치 상태는 존중)
            await failover(reason: "Wi-Fi 복귀 실패", force: true, manual: true, auto: !manual)
        }
    }

    // MARK: 수동 조작

    func connectNow(_ name: String) async {
        if busy {
            cancelPending("수동 연결 요청")
            for _ in 0..<30 where busy { try? await Task.sleep(for: .milliseconds(500)) }
            guard !busy else { log("이전 작업이 끝나지 않아 수동 연결을 시작하지 못함", .warning); return }
        }
        generation += 1
        let gen = generation
        let token = newToken(auto: false)
        busy = true
        setStatus(.connecting(name))
        log("수동 연결: \(name)")
        let ok = await connect(to: name, force: true, gen: gen, token: token)
        busy = false
        if ok {
            currentTetherDevice = name
            manualTether = true   // 수동 연결 시 자동 복귀 안 함
            lastSwitch = Date()
            log("✅ \(name) 핫스팟으로 연결됨", .success)
        } else {
            log("\(name) 연결 실패", .error)
        }
        refreshSnapshot()
        refreshStatus()
    }

    func checkNow() async {
        lastAttempt = nil
        tick = 2
        await step()
    }
}
