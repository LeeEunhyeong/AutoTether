import Foundation
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import Defaults

// macOS always sleeps on lid close without an external display, so this needs
// `pmset disablesleep 1`, which the privileged helper runs on our behalf.
@MainActor @Observable
final class SleepGuard {
    enum HelperState { case notInstalled, needsApproval, ready, unavailable }

    static let legacySudoersPath = "/etc/sudoers.d/autotether"

    private(set) var sleepDisabled = false
    private(set) var stateKnown = false
    private(set) var owned = false
    private(set) var batteryPercent: Int?
    private(set) var onBattery: Bool?
    private(set) var lastReason: String?
    private(set) var helperState: HelperState = .notInstalled
    private(set) var consented = false

    @ObservationIgnored private let helper = PrivilegedHelper()
    private let passive: Bool
    private var idleAssertion: IOPMAssertionID = 0
    private var busy = false
    private var rerunRequested = false
    private var lastTethered = false
    private var registrationRequested = false
    private var legacyCleanupDone = false
    private var lastUpgradeTry: Date?
    private var statusRefresh: Task<Void, Never>?
    // Only show the auth sheet right after the user flips the switch on.
    private var consentPromptAllowed = false
    // Bumped on every user change so an auth result that arrives late can be discarded.
    private var prefEpoch = 0

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    init(passive: Bool = false) {
        self.passive = passive
        refreshBattery()
    }

    // MARK: - User actions

    func userEnabledLidSleep() {
        prefEpoch += 1
        consentPromptAllowed = true
    }

    func userDisabledLidSleep() {
        prefEpoch += 1
        consentPromptAllowed = false
        Defaults[.pendingConsentRevoke] = true
    }

    func requestApproval() {
        if helperState == .notInstalled { _ = helper.register() }
        helper.openApprovalSettings()
        Task { await refreshHelperStatus() }
    }

    func restoreOnQuit() {
        updateIdleAssertion(false)
        helper.releaseSync()
    }

    // MARK: - Status

    // Several callers can ask at once; an upgrade must only ever run from one of them.
    func refreshHelperStatus() async {
        if let statusRefresh {
            await statusRefresh.value
            return
        }
        let task = Task { await updateHelperStatus() }
        statusRefresh = task
        await task.value
        statusRefresh = nil
    }

    private func updateHelperStatus() async {
        switch helper.registration {
        case .requiresApproval:
            helperState = .needsApproval
        case .notRegistered, .notFound:
            helperState = .notInstalled
        case .enabled:
            // Only a confirmed older version is replaced; timeouts and transport errors just mean "not now".
            guard let status = try? await helper.status() else {
                helperState = .unavailable
                return
            }
            guard status.version == HelperConstants.protocolVersion else {
                helperState = .unavailable
                if status.version < HelperConstants.protocolVersion, await upgradeHelper(from: status.version) {
                    await updateHelperStatus()
                }
                return
            }
            helperState = .ready
            consented = status.consented
        }
        if helperState == .ready { await cleanupLegacySudoers() }
    }

    private func upgradeHelper(from version: Int) async -> Bool {
        guard Defaults[.helperUpgradeAttemptedFor] != Self.appVersion else { return false }
        if let last = lastUpgradeTry, Date().timeIntervalSince(last) < 60 { return false }
        lastUpgradeTry = Date()
        log("권한 헬퍼 교체 시도 (v\(version) → v\(HelperConstants.protocolVersion))")
        guard (try? await helper.prepareForUpgrade()) == true else {
            log("헬퍼가 복구를 확인하지 못해 교체를 미룸 (1분 뒤 다시 시도)", .warning)
            return false
        }
        Defaults[.helperUpgradeAttemptedFor] = Self.appVersion
        helper.invalidate()
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    func refreshState() async {
        if helperState == .ready, let status = try? await helper.status(), status.state >= 0 {
            stateKnown = true
            sleepDisabled = status.state == 1
            owned = status.owned
        } else {
            await readPmset()
            owned = false
        }
    }

    private func readPmset() async {
        applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
    }

    private func applyPmset(_ result: Shell.Result) {
        let line = result.output.split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace) }
            .first { $0.count >= 2 && $0[0] == "SleepDisabled" }
        let value = line.flatMap { ["0": false, "1": true][String($0[1])] }
        stateKnown = result.ok && value != nil
        if let value { sleepDisabled = value }
    }

    func refreshBattery() {
        batteryPercent = nil
        onBattery = nil
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        onBattery = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            batteryPercent = current * 100 / max
        }
    }

    // MARK: - Reconcile

    private func desired() -> (on: Bool, reason: String?) {
        refreshBattery()
        guard Defaults[.preventLidSleep] else { return (false, nil) }
        if Defaults[.lidSleepOnlyWhileTethered] && !lastTethered { return (false, "테더링 중이 아님") }
        let floor = Defaults[.lidSleepBatteryFloor]
        guard floor > 0 else { return (true, nil) }
        switch onBattery {
        case nil:
            return (false, "전원 상태 확인 불가")
        case true?:
            guard let pct = batteryPercent else { return (false, "배터리 잔량 확인 불가") }
            if pct <= floor { return (false, "배터리 \(pct)% (하한 \(floor)%)") }
        case false?:
            break
        }
        return (true, nil)
    }

    func reconcile(isTethered: Bool) async {
        lastTethered = isTethered
        guard !passive else { return }
        guard !busy else {
            rerunRequested = true
            return
        }
        busy = true
        defer { busy = false }
        repeat {
            rerunRequested = false
            await reconcileOnce()
        } while rerunRequested
    }

    private func reconcileOnce() async {
        let startEpoch = prefEpoch
        await refreshHelperStatus()
        let prefOn = Defaults[.preventLidSleep]

        if !prefOn && consented { Defaults[.pendingConsentRevoke] = true }
        await revokeIfPending()

        if prefOn && helperState != .ready {
            await registerIfNeeded()
            await revokeIfPending()
            guard helperState == .ready else {
                lastReason = helperState == .unavailable ? "권한 헬퍼 응답 없음" : "권한 헬퍼 승인 필요 (시스템 설정 › 로그인 항목)"
                await refreshState()
                updateIdleAssertion(false)
                return
            }
        }

        // Nothing turns on until the previous revocation is confirmed.
        if Defaults[.pendingConsentRevoke] {
            lastReason = prefOn ? "이전 권한 반납 확인 대기 중" : nil
            updateIdleAssertion(false)
            if !prefOn { await turnOffIfOwned() }
            return
        }

        if prefOn && !consented {
            guard await obtainConsent() else { return }
        }

        await refreshState()
        guard stateKnown else {
            lastReason = "전원 상태 확인 불가"
            return
        }

        let (want, reason) = desired()
        lastReason = reason
        if want {
            guard startEpoch == prefEpoch, !Defaults[.pendingConsentRevoke], Defaults[.preventLidSleep] else {
                rerunRequested = true
                return
            }
            await apply(true, adopt: Defaults[.weDisabledSleep])
        } else if helperState == .ready && sleepDisabled && (owned || Defaults[.weDisabledSleep]) {
            // Take over what the sudoers version left on, then turn it off.
            if !owned { await apply(true, adopt: true) }
            await apply(false, adopt: false, reason: reason)
        } else {
            updateIdleAssertion(false)
        }
    }

    private func revokeIfPending() async {
        guard Defaults[.pendingConsentRevoke], helperState == .ready else { return }
        if (try? await helper.revokeConsent()) == true {
            Defaults[.pendingConsentRevoke] = false
            consented = false
            log("잠자기 방지 권한 반납 확인 (다시 켤 때 인증 필요)")
        } else {
            log("권한 반납을 확인하지 못함 — 다음 확인 때 다시 시도", .warning)
        }
    }

    private func registerIfNeeded() async {
        guard helperState == .notInstalled, !registrationRequested else { return }
        registrationRequested = true
        let result = helper.register()
        if result == .enabled {
            log("잠자기 방지 권한 헬퍼 등록 요청 → 사용 가능", .success)
        } else {
            log("잠자기 방지 권한 헬퍼 등록 요청 → 시스템 설정에서 승인 필요", .warning)
            if result == .requiresApproval { helper.openApprovalSettings() }
        }
        await refreshHelperStatus()
    }

    private func obtainConsent() async -> Bool {
        guard consentPromptAllowed else {
            lastReason = "인증 필요 — 설정에서 잠자기 방지를 다시 켜 주세요"
            updateIdleAssertion(false)
            await refreshState()
            return false
        }
        consentPromptAllowed = false
        let epoch = prefEpoch
        NSApp.activate()
        let result = await helper.authorizeAndGrant()

        // The helper may have recorded consent even if we never saw the reply, so revoke on any doubt.
        if epoch != prefEpoch || !Defaults[.preventLidSleep] {
            Defaults[.pendingConsentRevoke] = true
            log("인증 중 설정이 바뀌어 인증 결과를 사용하지 않음", .warning)
            return false
        }
        guard result.ok else {
            Defaults[.pendingConsentRevoke] = true
            Defaults[.preventLidSleep] = false
            lastReason = nil
            log("잠자기 방지를 켜지 않음: \(result.message)", .warning)
            return false
        }
        consented = true
        log("macOS 인증 완료 — 잠자기 방지 권한을 받음", .success)
        return true
    }

    private func turnOffIfOwned() async {
        guard helperState == .ready else { return }
        await refreshState()
        if owned && sleepDisabled { await apply(false, adopt: false) }
    }

    private func apply(_ on: Bool, adopt: Bool, reason: String? = nil) async {
        let wasOn = sleepDisabled && owned
        do {
            let result = try await helper.setSleepDisabled(on, adoptExisting: adopt)
            if result.ok && adopt { Defaults[.weDisabledSleep] = false }
            if !result.ok { log("잠자기 설정 변경 실패: \(result.message)", .error) }
        } catch {
            log("권한 헬퍼 호출 실패: \(error)", .error)
        }
        await refreshState()
        updateIdleAssertion(on && sleepDisabled)
        if on && sleepDisabled && owned && !wasOn {
            log("덮개를 닫아도 깨어 있음 (잠자기 방지 ON)", .success)
        } else if !on && wasOn && !sleepDisabled {
            log("잠자기 방지 OFF" + (reason.map { " — \($0)" } ?? ""))
        }
    }

    private func updateIdleAssertion(_ on: Bool) {
        if on, idleAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "AutoTether: 덮개 닫힘 잠자기 방지" as CFString, &idleAssertion)
        } else if !on, idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
    }

    // MARK: - Migration from the sudoers version

    func restoreLegacyIfNeeded() {
        guard !passive, Defaults[.weDisabledSleep],
              FileManager.default.fileExists(atPath: Self.legacySudoersPath) else { return }
        _ = Shell.runSync("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 5)
        applyPmset(Shell.runSync("/usr/bin/pmset", ["-g"], timeout: 3))
        if stateKnown && !sleepDisabled {
            Defaults[.weDisabledSleep] = false
            log("이전 버전이 켠 잠자기 방지를 복구함")
        }
    }

    private func cleanupLegacySudoers() async {
        guard !legacyCleanupDone else { return }
        guard FileManager.default.fileExists(atPath: Self.legacySudoersPath) else {
            legacyCleanupDone = true
            return
        }
        await readPmset()
        guard stateKnown else { return }
        // Restore with the old rule before deleting it.
        if sleepDisabled && Defaults[.weDisabledSleep] {
            _ = await Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 5)
            await readPmset()
            guard stateKnown && !sleepDisabled else { return }
            Defaults[.weDisabledSleep] = false
            log("이전 버전이 켠 잠자기 방지를 복구함")
        }
        if (try? await helper.removeLegacySudoers()) == true {
            legacyCleanupDone = true
            log("이전 버전의 sudoers 규칙(계정 전체 권한)을 제거함", .success)
        }
    }

    // MARK: - Uninstall

    func uninstallHelper() async {
        guard !passive else { return }
        guard !busy else {
            log("잠자기 설정 변경 중 — 잠시 후 다시 시도하세요", .warning)
            return
        }
        busy = true
        defer { busy = false }

        Defaults[.preventLidSleep] = false
        Defaults[.pendingConsentRevoke] = true
        if helperState == .ready {
            _ = try? await helper.setSleepDisabled(false, adoptExisting: false)
            if (try? await helper.revokeConsent()) == true {
                Defaults[.pendingConsentRevoke] = false
                consented = false
            }
        }

        // Check the real power state ourselves; never remove the helper while sleep may still be disabled.
        await readPmset()
        guard stateKnown && !sleepDisabled else {
            log("잠자기 방지가 아직 켜져 있거나 상태를 확인할 수 없어 헬퍼를 제거하지 않음", .error)
            await refreshHelperStatus()
            return
        }
        do {
            try await helper.unregister()
            log("잠자기 방지 권한 헬퍼 등록 해제됨")
        } catch {
            log("헬퍼 등록 해제 실패: \(error.localizedDescription)", .error)
        }
        updateIdleAssertion(false)
        registrationRequested = false
        await refreshHelperStatus()
        await refreshState()
    }
}
