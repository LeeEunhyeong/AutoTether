import Foundation
import Security
import ServiceManagement

@MainActor
final class PrivilegedHelper {
    enum Registration {
        case notRegistered, requiresApproval, enabled, notFound
    }

    struct Status {
        let state: Int
        let owned: Bool
        let version: Int
        let consented: Bool
    }

    struct SetResult {
        let ok: Bool
        let state: Int
        let message: String
    }

    enum HelperError: Error {
        case unavailable(String)
        case timeout
    }

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    var registration: Registration {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        default: .notFound
        }
    }

    func register() -> Registration {
        do {
            try service.register()
        } catch {
            // Also thrown when the daemon is already registered and waiting for approval.
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
        if let connection { return connection }
        guard let teamID = CodeIdentity.teamID else { throw HelperError.unavailable("앱에 팀 서명이 없음") }
        let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: AutoTetherHelperProtocol.self)
        c.setCodeSigningRequirement(HelperConstants.requirement(identifier: HelperConstants.helperIdentifier, teamID: teamID))
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    private func call<T: Sendable>(timeout: Double = HelperConstants.replyTimeout,
                                   _ body: @escaping (AutoTetherHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async throws -> T {
        let c = try makeConnection()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(HelperError.unavailable(error.localizedDescription)))
            }
            guard let helper = proxy as? AutoTetherHelperProtocol else {
                once.resume(.failure(HelperError.unavailable("proxy")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.failure(HelperError.timeout)) }
            body(helper) { once.resume(.success($0)) }
        }
    }

    func status() async throws -> Status {
        try await call(timeout: 15) { helper, done in
            helper.status { state, owned, version, consented in
                done(Status(state: state, owned: owned, version: version, consented: consented))
            }
        }
    }

    func setSleepDisabled(_ on: Bool, adoptExisting: Bool) async throws -> SetResult {
        try await call { helper, done in
            helper.setSleepDisabled(on, adoptExisting: adoptExisting) { ok, state, message in
                done(SetResult(ok: ok, state: state, message: message))
            }
        }
    }

    func revokeConsent() async throws -> Bool {
        try await call { helper, done in helper.revokeConsent { done($0) } }
    }

    func prepareForUpgrade() async throws -> Bool {
        try await call { helper, done in helper.prepareForUpgrade { done($0) } }
    }

    func removeLegacySudoers() async throws -> Bool {
        try await call { helper, done in helper.removeLegacySudoers { done($0) } }
    }

    func authorizeAndGrant() async -> (ok: Bool, message: String) {
        guard let grant = await Task.detached(priority: .userInitiated, operation: { AuthGrant.obtain() }).value else {
            return (false, "인증이 취소되었거나 실패함")
        }
        defer { grant.destroy() }
        do {
            return try await call { helper, done in
                helper.grantConsent(grant.externalForm) { ok, message in done((ok, message)) }
            }
        } catch {
            return (false, "권한 헬퍼 호출 실패: \(error)")
        }
    }

    // Called on quit. If this doesn't get through, the helper still restores when the connection drops.
    func releaseSync() {
        guard let connection else { return }
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? AutoTetherHelperProtocol
        proxy?.setSleepDisabled(false, adoptExisting: false) { _, _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
        invalidate()
    }
}

private final class AuthGrant: @unchecked Sendable {
    let ref: AuthorizationRef
    let externalForm: Data

    private init(ref: AuthorizationRef, externalForm: Data) {
        self.ref = ref
        self.externalForm = externalForm
    }

    static func obtain() -> AuthGrant? {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        let status = HelperConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        var external = AuthorizationExternalForm()
        guard status == errAuthorizationSuccess, AuthorizationMakeExternalForm(ref, &external) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        return AuthGrant(ref: ref, externalForm: withUnsafeBytes(of: &external) { Data($0) })
    }

    func destroy() {
        AuthorizationFree(ref, [.destroyRights])
    }
}

private final class ResumeOnce<V>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<V, Error>?

    init(_ continuation: CheckedContinuation<V, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<V, Error>) {
        let c = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
