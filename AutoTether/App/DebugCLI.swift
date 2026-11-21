#if DEBUG
import Foundation
import AppKit
import CoreWLAN
import Defaults

/// 개발/검증용 CLI 모드
///   AutoTether --status                 현재 네트워크/기기 상태 출력 후 종료
///   AutoTether --test-connect "<기기 이름>" 해당 기기 핫스팟을 켜고 연결 → 사용량 샘플링 → 결과 출력 후 종료
@MainActor
enum DebugCLI {
    static var isActive: Bool {
        let a = CommandLine.arguments
        return ["--status", "--test-connect", "--test-failover", "--test-cancel", "--filter-test", "--probe-join", "--snapshot", "--osa-test"].contains(where: a.contains)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        let model = AppModel.shared
        if args.contains("--osa-test") {
            // Hardened Runtime에서 NSAppleScript(do shell script)가 동작하는지 확인 (관리자 권한 없이)
            var err: NSDictionary?
            let r = NSAppleScript(source: "do shell script \"/usr/bin/id -u\"")?.executeAndReturnError(&err)
            out("osa result=\(r?.stringValue ?? "nil") error=\(err.map { "\($0)" } ?? "none")")
            exit(err == nil ? 0 : 1)
        }
        if args.contains("--status") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                let s = NetworkSnapshot.current()
                out("primary=\(s.primaryInterface ?? "-") addresses=\(s.addresses) wifi=\(s.wifiInterface ?? "-") powered=\(s.wifiPowered) ssid=\(s.ssid ?? "(위치권한 없음/미연결)")")
                out("hasLink=\(s.hasLink) tethered=\(s.isTethered) tetherIface=\(s.tetherInterface ?? "-")")
                out("internet=\(await InternetProbe.check())")
                out("location=\(model.location.statusText) hotspotAPI=\(model.hotspots.isAvailable)")
                for d in model.hotspots.devices { out("device: \(d.name) model=\(d.model) battery=\(d.battery)% signal=\(d.signal)") }
                out("sleepDisabled=\(model.sleep.sleepDisabled) helper=\(model.sleep.helperInstalled) battery=\(model.sleep.batteryPercent.map(String.init) ?? "-")% onBattery=\(model.sleep.onBattery)")
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--probe-join"), i + 1 < args.count {
            let name = args[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard let dev = model.hotspots.device(named: name) else { out("device not found"); exit(2) }
                let t0 = Date()
                guard let r = try? await model.hotspots.enableHotspot(dev) else { out("enable failed"); exit(3) }
                out(String(format: "enabled in %.1fs (password received: %@)", Date().timeIntervalSince(t0), r.password == nil ? "no" : "yes"))
                guard let wifi = CWWiFiClient.shared().interface() else { exit(4) }
                for n in 0..<20 {
                    let directed = (try? wifi.scanForNetworks(withName: r.ssid, includeHidden: true)) ?? []
                    let nets = directed
                    let match = nets.filter { $0.ssid == r.ssid || $0.ssid == nil }
                    out("directed=\(directed.count) ssids=\(directed.map { $0.ssid ?? "<hidden>" })")
                    let similar = nets.compactMap(\.ssid).filter { $0.lowercased().contains(name.prefix(4).lowercased()) }
                    out(String(format: "t=%.0fs scan total=%d match=%d similar=%@", Date().timeIntervalSince(t0), nets.count, match.count, similar.description))
                    if args.contains("--securities"), !match.isEmpty {
                        let all: [(String, CWSecurity)] = [("none", .none), ("WEP", .WEP), ("wpaPersonal", .wpaPersonal),
                            ("wpaPersonalMixed", .wpaPersonalMixed), ("wpa2Personal", .wpa2Personal), ("personal", .personal),
                            ("dynamicWEP", .dynamicWEP), ("wpaEnterprise", .wpaEnterprise), ("wpaEnterpriseMixed", .wpaEnterpriseMixed),
                            ("wpa2Enterprise", .wpa2Enterprise), ("enterprise", .enterprise), ("wpa3Personal", .wpa3Personal),
                            ("wpa3Enterprise", .wpa3Enterprise), ("wpa3Transition", .wpa3Transition), ("OWE", .OWE), ("oweTransition", .oweTransition)]
                        for n in match {
                            out("bssid=\(n.bssid ?? "nil") rssi=\(n.rssiValue) supports=\(all.filter { n.supportsSecurity($0.1) }.map(\.0))")
                        }
                        exit(0)
                    }
                    if let net = match.max(by: { $0.rssiValue < $1.rssiValue }) {
                        out("found rssi=\(net.rssiValue) ch=\(net.wlanChannel?.channelNumber ?? -1) band=\(net.wlanChannel?.channelBand.rawValue ?? -1)")
                        do {
                            try wifi.associate(to: net, password: r.password)
                            out("associate OK")
                        } catch { out("associate error: \(error)") }
                        try? await Task.sleep(for: .seconds(4))
                        let s = NetworkSnapshot.current()
                        out("tethered=\(s.isTethered) addrs=\(s.addresses)")
                        exit(s.isTethered ? 0 : 1)
                    }
                    if n == 0 { _ = name }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                exit(5)
            }
        }
        if let i = args.firstIndex(of: "--filter-test"), i + 1 < args.count {
            // 연결 없이 Evil Twin 필터 판정만 확인: 주변의 실제 AP(SSID)를 핫스팟 후보로 가정
            let ssid = args[i + 1]
            Task { @MainActor in
                guard let wifi = CWWiFiClient.shared().interface() else { exit(2) }
                if ssid == "*" {
                    // 주변 전체 AP를 대상으로 필터 분류 (SSID는 출력하지 않음)
                    guard let all = try? wifi.scanForNetworks(withName: nil) else { out("scan failed"); exit(2) }
                    var cat: [String: Int] = [:]
                    for n in all {
                        let one = WiFiControl.selectHotspotCandidates([n], requireWPA3: true)
                        let loose = WiFiControl.selectHotspotCandidates([n], requireWPA3: false)
                        let k = one.accepted.count == 1 ? "허용(WPA3)" : loose.accepted.count == 1 ? "WPA3요구시 거부(WPA2전용)" : (n.supportsSecurity(.none) ? "항상 거부(개방형)" : "항상 거부(기타 보안)")
                        cat[k, default: 0] += 1
                    }
                    out("total=\(all.count) \(cat.sorted { $0.key < $1.key })")
                    exit(0)
                }
                guard let nets = try? wifi.scanForNetworks(withName: ssid, includeHidden: true) else { out("scan failed"); exit(2) }
                let named = Array(nets.filter { $0.ssid == ssid })
                for n in named { out("candidate bssid=\(n.bssid ?? "nil") wpa2=\(n.supportsSecurity(.wpa2Personal)) wpa3=\(WiFiControl.supportsWPA3(n)) open=\(n.supportsSecurity(.none))") }
                for req in [false, true] {
                    let r = WiFiControl.selectHotspotCandidates(named, requireWPA3: req)
                    out("requireWPA3=\(req): accepted=\(r.accepted.count) rejectedSecurity=\(r.rejectedSecurity) rejectedNoWPA3=\(r.rejectedNoWPA3)")
                }
                exit(0)
            }
        }
        if args.contains("--test-cancel") {
            // 자동 전환 시작 3초 후 마스터 스위치 OFF → 연결 없이 중단돼야 함
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                let before = Defaults[.isEnabled]
                Defaults[.isEnabled] = true
                let t0 = Date()
                let work = Task { await model.engine.failover(reason: "취소 테스트", force: true, manual: true, auto: true) }
                try? await Task.sleep(for: .seconds(3))
                Defaults[.isEnabled] = false
                model.engine.cancelPending("테스트: 스위치 OFF")
                await work.value
                try? await Task.sleep(for: .seconds(3))
                let s = NetworkSnapshot.current()
                out(String(format: "CANCEL finished in %.1fs tethered=%@", Date().timeIntervalSince(t0), s.isTethered ? "true" : "false"))
                Defaults[.isEnabled] = before
                exit(s.isTethered ? 1 : 0)
            }
        }
        if args.contains("--test-failover") {
            // 자동 전환 경로(BSSID strict 모드) 시험: 현재 Wi-Fi에서도 강제로 우선순위 전환 → 결과 → 복귀
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                out("wpa3(before)=\(Defaults[.hotspotWPA3])")
                await model.engine.failover(reason: "진단 테스트", force: true, manual: true, auto: true)
                let s = NetworkSnapshot.current()
                let sec = CWWiFiClient.shared().interface()?.security()
                let sae = sec == .wpa3Personal
                let onPriority = Defaults[.priority].contains { $0.name == s.ssid }
                out("FAILOVER tethered=\(s.isTethered) ssid=\(s.ssid ?? "-") security=\(sec?.rawValue ?? -1) sae=\(sae)")
                if s.isTethered {
                    let netOK = await InternetProbe.check()
                    out("internet=\(netOK)")
                    await model.engine.returnToWiFi(manual: true)
                    let b = NetworkSnapshot.current()
                    let backOK = await InternetProbe.check()
                    out("RETURN tethered=\(b.isTethered) onWiFi=\(b.isOnWiFi) internet=\(backOK)")
                    // 통과 조건: 우선순위 기기에 실제 WPA3(SAE)로 연결 + 인터넷 + 일반 Wi-Fi 복귀 + 복귀 후 인터넷
                    exit(onPriority && sae && netOK && !b.isTethered && b.isOnWiFi && backOK ? 0 : 1)
                }
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "--test-connect"), i + 1 < args.count {
            let name = args[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await model.engine.connectNow(name)
                let s = NetworkSnapshot.current()
                out("RESULT tethered=\(s.isTethered) iface=\(s.tetherInterface ?? "-") addr=\(s.tetherInterface.flatMap { s.addresses[$0] } ?? "-") security=\(CWWiFiClient.shared().interface()?.security().rawValue ?? -1) pins=\(Defaults[.pinnedBSSIDs].mapValues(\.count))")
                if s.isTethered {
                    out("internet=\(await InternetProbe.check())")
                    for _ in 0..<5 { model.usage.sample(); try? await Task.sleep(for: .seconds(2)) }
                    out("session rx=\(model.usage.sessionRx) tx=\(model.usage.sessionTx) down=\(Int(model.usage.downloadSpeed))B/s")
                    if args.contains("--and-return") {
                        await model.engine.returnToWiFi(manual: true)
                        let b = NetworkSnapshot.current()
                        out("RETURN tethered=\(b.isTethered) ssid=\(b.ssid ?? "-") internet=\(await InternetProbe.check())")
                        model.usage.sample()
                    }
                }
                // 성공 = 요청한 핫스팟(SSID)에 실제 연결 + (--and-return이면) 일반 Wi-Fi로 복귀까지
                let requested = s.isTethered && (s.ssid == nil || s.ssid == name)
                var returned = true
                if args.contains("--and-return") {
                    let b = NetworkSnapshot.current()
                    returned = !b.isTethered && b.isOnWiFi
                }
                exit(requested && returned ? 0 : 1)
            }
        }
    }

    private static func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
}
#endif
