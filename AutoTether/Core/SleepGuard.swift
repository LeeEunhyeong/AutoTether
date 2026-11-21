import Foundation
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import Defaults

/// 덮개를 닫아도 잠자기하지 않게 하기.
/// macOS는 외부 디스플레이 없이 덮개를 닫으면 무조건 잠자기 → `pmset -a disablesleep 1`(root) 필요.
///
/// 보안 설계 (v1.1~)
/// - root 작업은 SMAppService로 등록한 전용 헬퍼(LaunchDaemon)만 수행. 사용자가 시스템 설정에서 한 번 승인.
/// - 잠자기 방지를 켤 때마다 macOS 인증 창(Touch ID 또는 관리자 암호)으로 동의를 받음.
///   헬퍼가 그 인증을 직접 검증해야만 켜 주고, 설정을 끄면 동의가 철회됨.
/// - 헬퍼는 같은 팀 서명의 AutoTether 앱 연결만 받고, 앱도 헬퍼 서명을 확인 (계정 전체 sudoers 권한 없음)
/// - 헬퍼가 켠 경우에만 끔. 앱 연결이 끊기면(종료·크래시) 헬퍼가 즉시 복구 → 감시 스크립트 불필요
/// - 배터리 하한·테더링 조건 판단은 앱이, 실제 변경과 소유권은 헬퍼의 직렬 큐가 담당
@MainActor @Observable
final class SleepGuard {
    enum HelperState: Equatable { case notInstalled, needsApproval, ready, unavailable }

    static let legacySudoersPath = "/etc/sudoers.d/autotether"

    private(set) var sleepDisabled = false
    /// 상태 조회 성공 여부 (실패를 '꺼짐'으로 오인하지 않기 위함)
    private(set) var stateKnown = false
    /// 헬퍼가 켠 상태인지 (헬퍼가 알려줌)
    private(set) var owned = false
    private(set) var batteryPercent: Int?
    /// nil = 전원 정보 확인 불가
    private(set) var onBattery: Bool? = nil
    private(set) var lastReason: String?
    private(set) var helperState: HelperState = .notInstalled
    /// 이 사용자가 macOS 인증으로 잠자기 방지에 동의했는지 (헬퍼가 알려줌)
    private(set) var consented = false

    @ObservationIgnored private let helper = PrivilegedHelper()
    private var idleAssertion: IOPMAssertionID = 0
    private var busy = false
    private var lastTethered = false
    /// 이번 실행에서 등록(승인 요청)을 이미 했는지 — 반복해서 알림을 띄우지 않기 위함
    private var registrationRequested = false
    private var legacyCleanupDone = false
    /// 사용자가 방금 설정을 켰음 → 다음 reconcile에서 인증 창을 띄워도 됨 (자동으로 인증 창이 뜨지 않게)
    private var consentPromptAllowed = false
    /// 사용자가 설정을 바꿀 때마다 증가 → 인증 창이 떠 있는 동안 설정이 바뀌면 그 인증 결과는 버림
    private var prefEpoch = 0
    /// 진단 CLI 모드: 헬퍼·전원 설정에 일절 손대지 않음
    private let passive: Bool
    /// reconcile 진행 중에 다시 요청이 들어옴 → 끝난 뒤 한 번 더 실행 (요청 유실 방지)
    private var rerunRequested = false
    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    init(passive: Bool = false) {
        self.passive = passive
        refreshBattery()
        guard !passive else { return }
        Task {
            await refreshHelperStatus()
            await refreshStateAsync()
        }
    }

    var helperInstalled: Bool { helperState == .ready }

    // MARK: 상태 조회

    func refreshHelperStatus() async {
        switch helper.registration {
        case .enabled:
            var needsUpgrade = false
            do {
                let s = try await helper.status()
                if s.version == HelperConstants.protocolVersion {
                    helperState = .ready
                    consented = s.consented
                } else {
                    needsUpgrade = true
                }
            } catch PrivilegedHelper.HelperError.timeout {
                helperState = .unavailable   // 응답이 늦을 뿐 → 교체하지 않음
            } catch {
                needsUpgrade = true          // 이전 프로토콜(메시지 형식 불일치) 가능성
            }
            if needsUpgrade {
                if Defaults[.helperUpgradeAttemptedFor] != Self.appVersion {
                    // 앱이 업데이트돼 이전 헬퍼가 실행 중일 수 있음 → 이 버전에서 한 번만 교체 시도
                    Defaults[.helperUpgradeAttemptedFor] = Self.appVersion
                    await upgradeHelper()
                    await refreshHelperStatus()
                    return
                }
                helperState = .unavailable
            }
        case .requiresApproval: helperState = .needsApproval
        case .notRegistered, .notFound: helperState = .notInstalled
        }
        if helperState == .ready { await cleanupLegacySudoersIfNeeded() }
    }

    /// 헬퍼 교체. 잠자기 방지가 꺼진 것을 확인한 상태에서만 이전 헬퍼를 내림.
    private func upgradeHelper() async {
        log("권한 헬퍼 교체 시도 (앱 v\(Self.appVersion))")
        do {
            // 새 프로토콜 헬퍼: 헬퍼가 새 활성화를 막고 복구를 확인한 뒤 스스로 종료
            if try await helper.prepareForUpgrade() {
                helper.invalidate()
                try? await Task.sleep(for: .seconds(2))
                return
            }
            log("헬퍼가 복구를 확인하지 못해 교체를 미룸", .warning)
            return
        } catch PrivilegedHelper.HelperError.timeout {
            // 헬퍼가 복구 중일 수 있음 → 절대 내리지 않음
            log("헬퍼 교체 준비 응답 없음 — 교체하지 않음", .warning)
            return
        } catch {
            // 이전 프로토콜(교체 기능 없음): 실제 전원 상태가 '꺼짐'일 때만 재등록
            applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
            guard stateKnown && !sleepDisabled else {
                log("잠자기 방지가 켜져 있거나 상태를 알 수 없어 헬퍼를 교체하지 않음", .warning)
                return
            }
            helper.invalidate()
            try? await helper.unregister()
            _ = helper.register()
            log("이전 헬퍼 등록을 갱신함 — 시스템 설정에서 다시 허용이 필요할 수 있음", .warning)
        }
    }

    /// 헬퍼가 준비됐으면 헬퍼에게, 아니면 `pmset -g`(권한 불필요)로 조회
    func refreshStateAsync() async {
        if helperState == .ready, let s = try? await helper.status(), s.state >= 0 {
            stateKnown = true
            sleepDisabled = s.state == 1
            owned = s.owned
            return
        }
        applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
        owned = false
    }

    private func applyPmset(_ r: Shell.Result) {
        var found: Bool?
        for line in r.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2 && parts[0] == "SleepDisabled" {
                if parts[1] == "1" { found = true } else if parts[1] == "0" { found = false }
            }
        }
        stateKnown = r.ok && found != nil
        if let found { sleepDisabled = found }
    }

    func refreshBattery() {
        batteryPercent = nil
        onBattery = nil
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let src = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        onBattery = src == kIOPMBatteryPowerKey
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,   // UPS/액세서리 배터리 제외
               let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                batteryPercent = cur * 100 / max
            }
        }
    }

    // MARK: 원하는 상태로 맞추기

    private func desired() -> (Bool, String?) {
        refreshBattery()
        guard Defaults[.preventLidSleep] else { return (false, nil) }
        if Defaults[.lidSleepOnlyWhileTethered] && !lastTethered { return (false, "테더링 중이 아님") }
        let floor = Defaults[.lidSleepBatteryFloor]
        if floor > 0 {
            switch onBattery {
            case .none: return (false, "전원 상태 확인 불가")   // 모르면 켜지 않음 (안전 쪽)
            case .some(true):
                guard let pct = batteryPercent else { return (false, "배터리 잔량 확인 불가") }
                if pct <= floor { return (false, "배터리 \(pct)% (하한 \(floor)%)") }
            case .some(false): break
            }
        }
        return (true, nil)
    }

    /// 설정 + 테더링 상태 + 배터리를 보고 원하는 상태로 맞춤
    func reconcile(isTethered: Bool) async {
        lastTethered = isTethered
        guard !passive else { return }
        guard !busy else { rerunRequested = true; return }
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
        var (want, reason) = desired()

        // 설정을 끄면 인증 동의도 철회 → 다시 켤 때 다시 인증. 철회가 '확인'될 때까지 재활성화 금지.
        if !prefOn && consented { Defaults[.pendingConsentRevoke] = true }
        if Defaults[.pendingConsentRevoke] && helperState == .ready {
            if (try? await helper.revokeConsent()) == true {
                Defaults[.pendingConsentRevoke] = false
                consented = false
                log("잠자기 방지 권한 반납 확인 (다시 켤 때 인증 필요)")
            } else {
                log("권한 반납을 확인하지 못함 — 다음 확인 때 다시 시도", .warning)
                // 아래 '철회 대기' 처리로 이어짐 (켜지 않고, 꺼져야 하면 끔)
            }
        }

        if prefOn && helperState != .ready {
            if helperState == .notInstalled && !registrationRequested {
                registrationRequested = true
                let r = helper.register()
                log("잠자기 방지 권한 헬퍼 등록 요청 → \(r == .enabled ? "사용 가능" : "시스템 설정에서 승인 필요")",
                    r == .enabled ? .success : .warning)
                if r == .requiresApproval { helper.openApprovalSettings() }
                await refreshHelperStatus()
            }
            if helperState == .ready && Defaults[.pendingConsentRevoke] {
                // 등록 직후: 남아 있던 이전 동의를 먼저 철회
                if (try? await helper.revokeConsent()) == true {
                    Defaults[.pendingConsentRevoke] = false
                    consented = false
                }
            }
            if helperState != .ready {
                reason = helperState == .unavailable ? "권한 헬퍼 응답 없음"
                                                     : "권한 헬퍼 승인 필요 (시스템 설정 › 로그인 항목)"
                lastReason = reason
                await refreshStateAsync()
                updateIdleAssertion(false)
                return
            }
        }

        // 철회가 확인되기 전에는 어떤 경우에도 켜지 않음
        if Defaults[.pendingConsentRevoke] {
            lastReason = prefOn ? "이전 권한 반납 확인 대기 중" : nil
            updateIdleAssertion(false)
            if !prefOn { await turnOffIfOwned(reason: nil) }
            return
        }

        // macOS 인증(Touch ID/관리자 암호)으로 동의 받기 — 사용자가 직접 켰을 때만 인증 창을 띄움
        if prefOn && helperState == .ready && !consented {
            guard consentPromptAllowed else {
                lastReason = "인증 필요 — 설정에서 잠자기 방지를 다시 켜 주세요"
                updateIdleAssertion(false)
                await refreshStateAsync()
                return
            }
            consentPromptAllowed = false
            let epoch = prefEpoch
            NSApp.activate()
            let r = await helper.authorizeAndGrant()
            if epoch != prefEpoch || !Defaults[.preventLidSleep] {
                // 인증하는 사이 사용자가 설정을 바꿈 → 결과 폐기, 헬퍼에 늦게 기록됐을 수 있으니 철회 예약
                Defaults[.pendingConsentRevoke] = true
                log("인증 중 설정이 바뀌어 인증 결과를 사용하지 않음", .warning)
                return
            }
            if r.ok {
                consented = true
                log("macOS 인증 완료 — 잠자기 방지 권한을 받음", .success)
            } else {
                // 응답 없음/시간 초과 등으로 실패했어도 헬퍼가 늦게 기록했을 수 있음 → 철회 예약
                Defaults[.pendingConsentRevoke] = true
                Defaults[.preventLidSleep] = false
                log("잠자기 방지를 켜지 않음: \(r.message)", .warning)
                lastReason = nil
                return
            }
        }

        await refreshStateAsync()
        guard stateKnown else { lastReason = "전원 상태 확인 불가"; return }   // 상태를 모르면 아무것도 바꾸지 않음

        // 헬퍼 호출 직전에 조건 재평가 (비동기 조회 사이 배터리/설정/테더링 변화 반영)
        (want, reason) = desired()
        lastReason = reason

        if want {
            // ON 요청 직전 최종 확인: 그사이 사용자가 설정을 바꿨거나 철회가 예약됐으면 켜지 않음
            guard startEpoch == prefEpoch, !Defaults[.pendingConsentRevoke], Defaults[.preventLidSleep] else {
                rerunRequested = true
                return
            }
            // 매번 보유 등록 (멱등): 헬퍼가 재시작돼 복구했어도 다시 켜짐
            await apply(true, adopt: Defaults[.weDisabledSleep])
        } else if helperState == .ready && (owned || Defaults[.weDisabledSleep]) && sleepDisabled {
            if !owned { await apply(true, adopt: true) }   // 예전 버전이 켠 상태를 넘겨받아 끔
            await apply(false, adopt: false, reason: reason)
        } else {
            updateIdleAssertion(false)
        }
    }

    private func turnOffIfOwned(reason: String?) async {
        guard helperState == .ready else { return }
        await refreshStateAsync()
        if owned && sleepDisabled { await apply(false, adopt: false, reason: reason) }
    }

    private func apply(_ on: Bool, adopt: Bool, reason: String? = nil) async {
        let wasOn = sleepDisabled && owned
        do {
            let r = try await helper.setSleepDisabled(on, adoptExisting: adopt)
            if r.ok && adopt { Defaults[.weDisabledSleep] = false }   // 소유권이 헬퍼로 이전됨
            if !r.ok { log("잠자기 설정 변경 실패: \(r.message)", .error) }
        } catch {
            log("권한 헬퍼 호출 실패: \(error)", .error)
        }
        await refreshStateAsync()
        updateIdleAssertion(on && sleepDisabled)
        if on && sleepDisabled && owned && !wasOn {
            log("덮개를 닫아도 깨어 있음 (잠자기 방지 ON)", .success)
        } else if !on && wasOn && !sleepDisabled {
            log("잠자기 방지 OFF" + (reason.map { " — \($0)" } ?? ""))
        }
    }

    /// 앱 종료 시: 헬퍼에 보유 해제를 알림 (응답이 없어도 프로세스가 끝나면 연결이 끊겨 헬퍼가 복구)
    func restoreOnQuit() {
        updateIdleAssertion(false)
        helper.releaseSync()
    }

    /// 사용자가 설정에서 잠자기 방지를 켰을 때 호출 → 다음 reconcile에서 인증 창 허용
    func userEnabledLidSleep() { consentPromptAllowed = true; prefEpoch += 1 }

    /// 사용자가 설정에서 잠자기 방지를 껐을 때 → 동의 철회 예약 (확인될 때까지 유지)
    func userDisabledLidSleep() {
        prefEpoch += 1
        consentPromptAllowed = false
        Defaults[.pendingConsentRevoke] = true
    }

    // MARK: 예전 sudoers 방식에서 이전

    /// 헬퍼가 아직 승인되지 않았는데 예전 버전이 켠 상태가 남아 있으면 예전 규칙으로 복구 (시작 시 1회)
    func restoreLegacyIfNeeded() {
        guard !passive else { return }
        guard Defaults[.weDisabledSleep], FileManager.default.fileExists(atPath: Self.legacySudoersPath) else { return }
        _ = Shell.runSync("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 5)
        applyPmset(Shell.runSync("/usr/bin/pmset", ["-g"], timeout: 3))
        if stateKnown && !sleepDisabled { Defaults[.weDisabledSleep] = false; log("이전 버전이 켠 잠자기 방지를 복구함") }
    }

    /// 예전 sudoers 규칙 제거. 예전 버전이 켠 잠자기 방지가 남아 있으면 먼저 그 규칙으로 복구한 뒤에 제거.
    private func cleanupLegacySudoersIfNeeded() async {
        guard !legacyCleanupDone else { return }
        guard FileManager.default.fileExists(atPath: Self.legacySudoersPath) else { legacyCleanupDone = true; return }
        applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
        guard stateKnown else { return }
        if sleepDisabled && Defaults[.weDisabledSleep] {
            _ = await Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], timeout: 5)
            applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
            guard stateKnown && !sleepDisabled else { return }   // 복구 확인 전에는 규칙을 지우지 않음
            Defaults[.weDisabledSleep] = false
            log("이전 버전이 켠 잠자기 방지를 복구함")
        }
        if (try? await helper.removeLegacySudoers()) == true {
            legacyCleanupDone = true   // 실패하면 다음 확인 때 다시 시도
            log("이전 버전의 sudoers 규칙(계정 전체 권한)을 제거함", .success)
        }
    }

    // MARK: 헬퍼 관리 (설정 화면)

    func requestApproval() {
        if helperState == .notInstalled { _ = helper.register() }
        helper.openApprovalSettings()
        Task { await refreshHelperStatus() }
    }

    func uninstallHelper() async {
        guard !passive else { return }
        guard !busy else { log("잠자기 설정 변경 중 — 잠시 후 다시 시도하세요", .warning); return }
        busy = true
        defer { busy = false }
        Defaults[.preventLidSleep] = false
        // 철회가 확인되지 않으면 예약을 남김 → 다시 등록될 때 켜기 전에 반드시 먼저 철회
        Defaults[.pendingConsentRevoke] = true
        if helperState == .ready {
            _ = try? await helper.setSleepDisabled(false, adoptExisting: false)
            if (try? await helper.revokeConsent()) == true {
                Defaults[.pendingConsentRevoke] = false
                consented = false
            }
        }
        // 헬퍼 응답과 무관하게 실제 전원 상태를 직접 확인: 켜져 있거나 모르면 헬퍼를 내리지 않음
        applyPmset(await Shell.run("/usr/bin/pmset", ["-g"], timeout: 3))
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
        await refreshStateAsync()
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
}
