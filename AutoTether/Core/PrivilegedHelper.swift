import Foundation
import Security
import ServiceManagement

/// root 권한 헬퍼(LaunchDaemon) 등록과 XPC 통신.
/// - 등록: SMAppService.daemon → 사용자가 시스템 설정 > 로그인 항목에서 한 번 승인(Touch ID/암호)
/// - 연결: 헬퍼 서명(같은 팀)을 확인한 뒤에만 사용. 헬퍼도 앱 서명을 확인함(양방향).
/// - 연결을 열어 둔 동안 앱이 '보유자'. 앱이 종료·크래시하면 연결이 끊기고 헬퍼가 즉시 복구.
@MainActor
final class PrivilegedHelper {
    enum Registration: Equatable {
        case notRegistered, requiresApproval, enabled, notFound
    }

    struct Status { let state: Int; let owned: Bool; let version: Int; let consented: Bool }
    struct SetResult { let ok: Bool; let state: Int; let message: String }

    enum HelperError: Error { case unavailable(String), timeout }

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    var registration: Registration {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// 등록 요청. 처음이면 macOS가 승인 알림을 띄우고 상태는 requiresApproval이 됨.
    func register() -> Registration {
        do {
            try service.register()
        } catch {
            // 이미 등록돼 승인 대기 중이면 오류로 오기도 함 → 상태로 판단
            log("권한 헬퍼 등록 요청: \(error.localizedDescription)", .warning)
        }
        return registration
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func unregister() async throws {
        invalidate()
        try await service.unregister()
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func makeConnection() throws -> NSXPCConnection {
        if let c = connection { return c }
        // 자기 자신의 팀 ID로 헬퍼를 검증. 서명이 없는(ad-hoc) 빌드면 헬퍼를 쓰지 않음 (실패 시 닫힘)
        guard let team = CodeIdentity.teamID else { throw HelperError.unavailable("앱에 팀 서명이 없음") }
        let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: AutoTetherHelperProtocol.self)
        c.setCodeSigningRequirement(HelperConstants.requirement(identifier: HelperConstants.helperIdentifier, teamID: team))
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    /// 응답/오류/타임아웃 중 먼저 오는 것 하나로 끝내는 호출
    private func call<T: Sendable>(timeout: Double = 10,
                                   _ body: @escaping (AutoTetherHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async throws -> T {
        let c = try makeConnection()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { err in
                once.resume(.failure(HelperError.unavailable(err.localizedDescription)))
            }
            guard let helper = proxy as? AutoTetherHelperProtocol else {
                once.resume(.failure(HelperError.unavailable("proxy"))); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.failure(HelperError.timeout)) }
            body(helper) { once.resume(.success($0)) }
        }
    }

    func status() async throws -> Status {
        try await call { h, done in h.status { s, o, v, c in done(Status(state: s, owned: o, version: v, consented: c)) } }
    }

    func setSleepDisabled(_ on: Bool, adoptExisting: Bool) async throws -> SetResult {
        try await call { h, done in
            h.setSleepDisabled(on, adoptExisting: adoptExisting) { ok, s, m in done(SetResult(ok: ok, state: s, message: m)) }
        }
    }

    func revokeConsent() async throws -> Bool {
        try await call { h, done in h.revokeConsent { done($0) } }
    }

    func prepareForUpgrade() async throws -> Bool {
        try await call(timeout: 5) { h, done in h.prepareForUpgrade { done($0) } }
    }

    /// macOS 인증 창(Touch ID 또는 관리자 암호)을 띄워 권한을 얻고, 헬퍼가 직접 검증하게 제출.
    /// 성공해야만 헬퍼가 잠자기 방지를 켜 줌. 취소하면 false.
    func authorizeAndGrant() async -> (ok: Bool, message: String) {
        let grant = await Task.detached(priority: .userInitiated) { AuthGrant.obtain() }.value
        guard let grant else { return (false, "인증이 취소되었거나 실패함") }
        defer { grant.destroy() }   // 헬퍼 검증이 끝난 뒤에 권한 폐기 (재사용 방지)
        do {
            let r: (Bool, String) = try await call(timeout: 15) { h, done in
                h.grantConsent(grant.externalForm) { ok, m in done((ok, m)) }
            }
            return r
        } catch {
            return (false, "권한 헬퍼 호출 실패: \(error)")
        }
    }

    func removeLegacySudoers() async throws -> Bool {
        try await call { h, done in h.removeLegacySudoers { done($0) } }
    }

    /// 앱 종료 시 동기 해제 (실패해도 프로세스 종료로 연결이 끊기면 헬퍼가 복구함)
    func releaseSync() {
        guard let c = connection else { return }
        let sem = DispatchSemaphore(value: 0)
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? AutoTetherHelperProtocol
        proxy?.setSleepDisabled(false, adoptExisting: false) { _, _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
        invalidate()
    }
}

/// macOS Authorization Services로 얻은 권한. 헬퍼에는 외부 형식(32바이트 토큰)만 전달.
private final class AuthGrant: @unchecked Sendable {
    let ref: AuthorizationRef
    let externalForm: Data
    private init(ref: AuthorizationRef, externalForm: Data) { self.ref = ref; self.externalForm = externalForm }

    /// 차단 호출 (인증 창이 닫힐 때까지 대기) → 메인 스레드 밖에서 호출
    static func obtain() -> AuthGrant? {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        let status: OSStatus = HelperConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { ptr in
                var rights = AuthorizationRights(count: 1, items: ptr)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        var ext = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &ext) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        let data = withUnsafeBytes(of: &ext) { Data($0) }
        return AuthGrant(ref: ref, externalForm: data)
    }

    func destroy() { AuthorizationFree(ref, [.destroyRights]) }
}

/// 연속체를 한 번만 재개 (응답·오류·타임아웃 경쟁)
private final class Once<V>: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    let cont: CheckedContinuation<V, Error>
    init(_ c: CheckedContinuation<V, Error>) { cont = c }
    func resume(_ r: Result<V, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(with: r)
    }
}
