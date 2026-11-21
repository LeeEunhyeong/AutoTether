#if DEBUG
import Foundation
import CoreWLAN
import Defaults

// Debug-only checks used by scripts/verify_security_cycle.sh:
//   --status, --test-connect <name> [--and-return], --test-failover, --test-cancel
@MainActor
enum DebugCLI {
    private static let knownFlags: Set<String> = [
        "--status", "--test-connect", "--and-return", "--test-failover", "--test-cancel", "--snapshot", "--demo-data",
    ]

    // A typo or a retired flag would otherwise launch the real app with automatic failover.
    static func rejectUnknownFlags() {
        let unknown = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") && !knownFlags.contains($0) }
        guard !unknown.isEmpty else { return }
        FileHandle.standardError.write(Data("unknown option: \(unknown.joined(separator: " "))\n".utf8))
        exit(2)
    }

    static var isActive: Bool {
        let flags = ["--status", "--test-connect", "--test-failover", "--test-cancel", "--snapshot"]
        return flags.contains(where: CommandLine.arguments.contains)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        let model = AppModel.shared

        func run(_ body: @escaping @MainActor () async -> Bool) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                exit(await body() ? 0 : 1)
            }
        }

        if args.contains("--status") {
            run {
                let s = NetworkSnapshot.current()
                out("primary=\(s.primaryInterface ?? "-") addresses=\(s.addresses) wifi=\(s.wifiInterface ?? "-") powered=\(s.wifiPowered) ssid=\(s.ssid ?? "(none)")")
                out("hasLink=\(s.hasLink) tethered=\(s.isTethered) tetherIface=\(s.tetherInterface ?? "-")")
                out("internet=\(await InternetProbe.check())")
                out("location=\(model.location.statusText) hotspotAPI=\(model.hotspots.isAvailable)")
                for d in model.hotspots.devices {
                    out("device: \(d.name) model=\(d.model) battery=\(d.battery)% signal=\(d.signal)")
                }
                let pmset = Shell.runSync("/usr/bin/pmset", ["-g"]).output
                let sleepDisabled = pmset.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace) == ["SleepDisabled", "1"] }
                out("sleepDisabled=\(sleepDisabled) battery=\(model.sleep.batteryPercent.map(String.init) ?? "-")%")
                return true
            }
        } else if let i = args.firstIndex(of: "--test-connect"), i + 1 < args.count {
            let name = args[i + 1]
            run {
                await model.engine.connectNow(name)
                let s = NetworkSnapshot.current()
                let security = CWWiFiClient.shared().interface()?.security().rawValue ?? -1
                out("RESULT tethered=\(s.isTethered) iface=\(s.tetherInterface ?? "-") security=\(security)")
                guard s.isTethered, s.ssid == nil || s.ssid == name else { return false }
                out("internet=\(await probeWithRetry())")
                for _ in 0..<5 {
                    model.usage.sample()
                    try? await Task.sleep(for: .seconds(2))
                }
                out("session rx=\(model.usage.sessionRx) tx=\(model.usage.sessionTx)")
                guard args.contains("--and-return") else { return true }
                await model.engine.returnToWiFi(manual: true)
                model.usage.sample()
                let back = NetworkSnapshot.current()
                out("RETURN tethered=\(back.isTethered) onWiFi=\(back.isOnWiFi) internet=\(await probeWithRetry())")
                return !back.isTethered && back.isOnWiFi
            }
        } else if args.contains("--test-failover") {
            run {
                await model.engine.failover(reason: "진단 테스트", force: true, manual: true, auto: true)
                let s = NetworkSnapshot.current()
                let sae = CWWiFiClient.shared().interface()?.security() == .wpa3Personal
                let onPriority = Defaults[.priority].contains { $0.name == s.ssid }
                out("FAILOVER tethered=\(s.isTethered) sae=\(sae)")
                guard s.isTethered else { return false }
                let online = await probeWithRetry()
                out("internet=\(online)")
                await model.engine.returnToWiFi(manual: true)
                let back = NetworkSnapshot.current()
                let backOnline = await probeWithRetry()
                out("RETURN tethered=\(back.isTethered) onWiFi=\(back.isOnWiFi) internet=\(backOnline)")
                return onPriority && sae && online && !back.isTethered && back.isOnWiFi && backOnline
            }
        } else if args.contains("--test-cancel") {
            run {
                let wasEnabled = Defaults[.isEnabled]
                Defaults[.isEnabled] = true
                let start = Date()
                let work = Task { await model.engine.failover(reason: "취소 테스트", force: true, manual: true, auto: true) }
                try? await Task.sleep(for: .seconds(3))
                Defaults[.isEnabled] = false
                model.engine.cancelPending("테스트: 스위치 OFF")
                await work.value
                try? await Task.sleep(for: .seconds(3))
                let tethered = NetworkSnapshot.current().isTethered
                out(String(format: "CANCEL finished in %.1fs tethered=%@", Date().timeIntervalSince(start), tethered ? "true" : "false"))
                Defaults[.isEnabled] = wasEnabled
                return !tethered
            }
        }
    }

    // DHCP and routing usually need a few seconds after joining.
    private static func probeWithRetry() async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            if await InternetProbe.check() { return true }
        }
        return false
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}
#endif
