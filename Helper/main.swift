import Foundation
import Security
import os

// AutoTether 권한 헬퍼 (root LaunchDaemon, SMAppService로 등록)
// - 서명 요구 사항을 만족하는 AutoTether 앱의 연결만 받음 (NSXPCListener.setConnectionCodeSigningRequirement)
// - 할 수 있는 일: pmset disablesleep 0/1, 상태 조회, 동의 기록/철회, 예전 sudoers 파일 제거, 업그레이드 전 복구·종료
// - 켜기는 사용자가 macOS 인증(Touch ID/관리자 암호)으로 얻은 권한을 헬퍼가 직접 검증한 뒤에만 허용
//   · 권한 규칙이 기대한 정책(관리자 인증·비공유·짧은 유효시간)인지 확인하고, 아니면 동의를 받지 않음
//   · 검증에 쓴 권한은 즉시 폐기 (같은 외부 형식 재사용 차단)
// - 모든 상태 변경은 하나의 직렬 큐에서 처리, pmset은 제한 시간 안에서만 실행
// - 기록(소유 표시·동의)이 디스크에 확실히 남았을 때만 상태를 바꿈 (장애 시 일관성)
// - 잠자기 방지를 요청한 연결이 모두 끊기면(앱 종료·크래시·강제 종료) 즉시 원래대로 복구

let logger = Logger(subsystem: "com.imgold.AutoTether.helper", category: "helper")

final class SleepController: @unchecked Sendable {
    static let dbDir = "/private/var/db"
    static let ownedMarker = "/private/var/db/com.imgold.AutoTether.helper.owned"
    static let legacySudoers = "/etc/sudoers.d/autotether"
    static let consentFile = "/private/var/db/com.imgold.AutoTether.helper.consent"

    let queue = DispatchQueue(label: "com.imgold.AutoTether.helper.sleep")
    /// 보유자: 연결 → 그 연결의 사용자
    private var holders: [ObjectIdentifier: uid_t] = [:]
    private var owned = false
    /// 인증으로 동의한 사용자 UID 목록 (root 전용 파일에 보관)
    private var consented = Set<uid_t>()
    /// 업그레이드 준비 중 → 새 활성화 거부
    private var upgrading = false
    /// 권한 규칙이 기대한 정책인지 (아니면 동의를 받지 않음)
    var authorizationPolicyValid = false

    init() {
        queue.sync {
            consented = Self.loadConsent()
            owned = FileManager.default.fileExists(atPath: Self.ownedMarker)
            if owned {
                // 이전 실행에서 켠 채로 끝남 (앱·헬퍼 크래시, 재부팅). 보유자가 없으므로 복구.
                logger.notice("previous ownership marker found; restoring")
                _ = restoreLocked()
            }
        }
    }

    // MARK: pmset (제한 시간)

    private func run(_ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "") }
        try? pipe.fileHandleForWriting.close()
        let buffer = Buffer()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                buffer.append(chunk)
            }
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            logger.error("pmset timed out: \(args.joined(separator: " "), privacy: .public)")
            if p.isRunning { p.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            return (-1, "")
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (p.terminationStatus, buffer.string)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { if data.count < 65_536 { data.append(d) } } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// -1 확인 불가, 0, 1
    private func readStateLocked() -> Int {
        let r = run(["-g"])
        guard r.status == 0 else { return -1 }
        for line in r.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2 && parts[0] == "SleepDisabled" {
                if parts[1] == "1" { return 1 }
                if parts[1] == "0" { return 0 }
                return -1
            }
        }
        return -1
    }

    // MARK: 원자적 파일 기록

    /// 같은 디렉터리의 임시 파일에 쓰고 fsync 후 rename → 실패하면 false (호출자가 상태 변경을 중단)
    private static func atomicWrite(_ body: String, to path: String) -> Bool {
        let tmp = "\(path).tmp.\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { logger.error("open temp file failed: \(errno)"); return false }
        let bytes = Array(body.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(tmp, path) == 0 else {
            logger.error("atomic write failed: \(errno)")
            unlink(tmp)
            return false
        }
        let dfd = open(dbDir, O_RDONLY)   // 디렉터리 항목도 디스크에 반영
        if dfd >= 0 { fsync(dfd); close(dfd) }
        return true
    }

    private static func remove(_ path: String) -> Bool {
        unlink(path) == 0 || errno == ENOENT
    }

    @discardableResult
    private func setOwnedLocked(_ v: Bool) -> Bool {
        if v {
            guard Self.atomicWrite("1\n", to: Self.ownedMarker) else { return false }
            owned = true
            return true
        }
        guard Self.remove(Self.ownedMarker) else { return false }
        owned = false
        return true
    }

    /// 헬퍼가 켠 경우에만 끄고, 꺼진 게 확인되면 소유권 해제
    private func restoreLocked() -> Bool {
        guard owned else { return true }
        for attempt in 1...3 {
            _ = run(["-a", "disablesleep", "0"])
            if readStateLocked() == 0 {
                if !setOwnedLocked(false) { logger.error("sleep restored but marker removal failed") }
                logger.notice("sleep restored (attempt \(attempt))")
                return true
            }
            usleep(500_000)
        }
        logger.error("failed to restore sleep; keeping ownership marker")
        return false
    }

    // MARK: 동의 (macOS 인증)

    private static func loadConsent() -> Set<uid_t> {
        var st = stat()
        guard lstat(consentFile, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == 0,
              let text = try? String(contentsOfFile: consentFile, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { uid_t($0) })
    }

    /// 동의 목록 저장. 실패하면 false → 동의 부여/철회를 성공으로 보고하지 않음
    private static func saveConsent(_ set: Set<uid_t>) -> Bool {
        if set.isEmpty { return remove(consentFile) }
        return atomicWrite(set.sorted().map(String.init).joined(separator: "\n") + "\n", to: consentFile)
    }

    private static let expectedRule: [String: Any] = [
        "class": "user", "group": "admin", "shared": false, "timeout": 30,
        "allow-root": false, "authenticate-user": true, "version": 1,
        "comment": "AutoTether: 덮개를 닫아도 잠자기하지 않도록 허용",
    ]

    /// 현재 인증 DB의 규칙이 기대한 정책과 같은지 (같은 이름의 완화된 규칙이 미리 등록돼 있으면 거부)
    private static func ruleIsValid() -> Bool {
        var def: CFDictionary?
        guard AuthorizationRightGet(HelperConstants.authorizationRight, &def) == errAuthorizationSuccess,
              let d = def as? [String: Any] else { return false }
        let timeout = (d["timeout"] as? NSNumber)?.intValue ?? Int.max
        return d["class"] as? String == "user"
            && d["group"] as? String == "admin"
            && (d["shared"] as? Bool) == false
            && (d["allow-root"] as? Bool ?? false) == false
            && (d["authenticate-user"] as? Bool ?? true) == true
            && timeout > 0 && timeout <= 30
            && d["rule"] == nil && d["mechanisms"] == nil   // 다른 규칙 위임·사용자 정의 메커니즘 금지
    }

    /// 권한 규칙 등록/교정. 결과가 기대한 정책일 때만 동의를 받음.
    func ensureAuthorizationRight() {
        if !Self.ruleIsValid() {
            var auth: AuthorizationRef?
            if AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth {
                let st = AuthorizationRightSet(auth, HelperConstants.authorizationRight, Self.expectedRule as CFDictionary,
                                               "AutoTether가 덮개를 닫아도 Mac이 잠자기하지 않도록 설정하려고 합니다." as CFString, nil, nil)
                logger.notice("authorization right (re)registered: \(st)")
                AuthorizationFree(auth, [])
            }
        }
        authorizationPolicyValid = Self.ruleIsValid()
        if !authorizationPolicyValid { logger.error("authorization rule is not the expected policy; consent disabled") }
    }

    /// 앱이 보낸 AuthorizationExternalForm을 헬퍼가 직접 검증 (상호작용 없이 → 사용자가 이미 인증했어야 성공).
    /// 검증 후 권한을 폐기해 같은 외부 형식을 다시 쓸 수 없게 함.
    func grantConsent(_ data: Data, uid: uid_t) -> (Bool, String) {
        guard authorizationPolicyValid else { return (false, "authorization policy invalid") }
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return (false, "invalid authorization") }
        var ext = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &ext) { data.copyBytes(to: $0) }
        var auth: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&ext, &auth) == errAuthorizationSuccess, let auth else {
            return (false, "authorization not usable")
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }   // 1회용: 검증에 쓴 권한 폐기
        let status: OSStatus = HelperConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { ptr in
                var rights = AuthorizationRights(count: 1, items: ptr)
                return AuthorizationCopyRights(auth, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            logger.notice("consent rejected: \(status)")
            return (false, "authorization denied (\(status))")
        }
        return queue.sync {
            var next = consented
            next.insert(uid)
            guard Self.saveConsent(next) else { return (false, "consent could not be saved") }
            consented = next
            logger.notice("consent granted for uid \(uid)")
            return (true, "granted")
        }
    }

    /// 이 사용자의 동의와 보유권만 철회. 남은 보유자가 없으면 복구.
    func revokeConsent(uid: uid_t) -> Bool {
        queue.sync {
            var next = consented
            next.remove(uid)
            guard Self.saveConsent(next) else { return false }
            consented = next
            holders = holders.filter { $0.value != uid }
            if holders.isEmpty { return restoreLocked() }
            return true
        }
    }

    // MARK: 요청 처리 (모두 직렬 큐)

    func status(uid: uid_t) -> (Int, Bool, Bool) {
        queue.sync { (readStateLocked(), owned, consented.contains(uid)) }
    }

    /// 업그레이드 준비: 새 활성화를 막고, 헬퍼가 켠 상태를 복구한 뒤에만 종료 허락
    func prepareForUpgrade() -> Bool {
        queue.sync {
            upgrading = true
            holders.removeAll()
            guard restoreLocked(), !owned else {
                upgrading = false
                return false
            }
            return true
        }
    }

    func set(_ on: Bool, adopt: Bool, client: ObjectIdentifier, uid: uid_t) -> (Bool, Int, String) {
        queue.sync {
            if !on {
                holders.removeValue(forKey: client)
                if holders.isEmpty && owned {
                    let ok = restoreLocked()
                    return (ok, readStateLocked(), ok ? "restored" : "restore failed")
                }
                return (true, readStateLocked(), owned ? "other holders remain" : "not owned; untouched")
            }
            guard !upgrading else { return (false, readStateLocked(), "upgrading") }
            guard consented.contains(uid) else {
                return (false, readStateLocked(), "consent required")   // 인증 없이 켜기 거부
            }
            let state = readStateLocked()
            switch state {
            case 1:
                if owned || adopt {
                    if !owned {
                        guard setOwnedLocked(true) else { return (false, 1, "cannot record ownership") }
                        logger.notice("adopted existing disablesleep")
                    }
                    holders[client] = uid
                    return (true, 1, "already on (owned)")
                }
                return (true, 1, "already on by another tool; not owned")
            case 0:
                // 1) 소유 표시가 디스크에 남은 것을 확인한 뒤에만 2) 변경
                guard setOwnedLocked(true) else { return (false, 0, "cannot record ownership; not changed") }
                holders[client] = uid
                _ = run(["-a", "disablesleep", "1"])
                let now = readStateLocked()
                if now == 1 { logger.notice("sleep disabled"); return (true, 1, "enabled") }
                holders.removeValue(forKey: client)
                _ = restoreLocked()
                return (false, readStateLocked(), "pmset enable failed")
            default:
                return (false, -1, "state unknown; not changed")
            }
        }
    }

    func clientGone(_ client: ObjectIdentifier) {
        queue.sync {
            guard holders.removeValue(forKey: client) != nil else { return }
            if holders.isEmpty && owned {
                logger.notice("last holder disconnected; restoring")
                _ = restoreLocked()
            }
        }
    }

    /// true = 파일이 없거나 지움
    func removeLegacySudoers() -> Bool {
        queue.sync {
            var st = stat()
            // 고정 경로, 심볼릭 링크는 따라가지 않음 (/etc/sudoers.d는 root 소유라 사용자가 바꿀 수 없음)
            guard lstat(Self.legacySudoers, &st) == 0 else { return errno == ENOENT }
            guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
            let ok = unlink(Self.legacySudoers) == 0
            if ok { logger.notice("legacy sudoers rule removed") }
            return ok
        }
    }
}

final class HelperService: NSObject, AutoTetherHelperProtocol {
    let controller: SleepController
    let client: ObjectIdentifier
    /// 연결한 프로세스의 사용자 (커널이 알려주는 값 — 앱이 주장하는 값이 아님)
    let uid: uid_t
    init(controller: SleepController, client: ObjectIdentifier, uid: uid_t) {
        self.controller = controller
        self.client = client
        self.uid = uid
    }
    func status(reply: @escaping (Int, Bool, Int, Bool) -> Void) {
        let (s, o, c) = controller.status(uid: uid)
        reply(s, o, HelperConstants.protocolVersion, c)
    }
    func grantConsent(_ authorization: Data, reply: @escaping (Bool, String) -> Void) {
        let (ok, m) = controller.grantConsent(authorization, uid: uid)
        reply(ok, m)
    }
    func revokeConsent(reply: @escaping (Bool) -> Void) {
        reply(controller.revokeConsent(uid: uid))
    }
    func setSleepDisabled(_ on: Bool, adoptExisting: Bool, reply: @escaping (Bool, Int, String) -> Void) {
        let (ok, s, m) = controller.set(on, adopt: adoptExisting, client: client, uid: uid)
        reply(ok, s, m)
    }
    func prepareForUpgrade(reply: @escaping (Bool) -> Void) {
        let ok = controller.prepareForUpgrade()
        reply(ok)
        if ok {
            logger.notice("restored and exiting for upgrade")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }   // 새 활성화는 이미 차단됨
        }
    }
    func removeLegacySudoers(reply: @escaping (Bool) -> Void) {
        reply(controller.removeLegacySudoers())
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let controller: SleepController
    init(controller: SleepController) { self.controller = controller }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // 서명 검사는 리스너 수준(setConnectionCodeSigningRequirement)에서 이미 강제됨
        let id = ObjectIdentifier(c)
        c.exportedInterface = NSXPCInterface(with: AutoTetherHelperProtocol.self)
        c.exportedObject = HelperService(controller: controller, client: id, uid: c.effectiveUserIdentifier)
        let controller = self.controller
        c.invalidationHandler = { controller.clientGone(id) }
        c.interruptionHandler = { controller.clientGone(id) }
        logger.info("accepted connection from pid \(c.processIdentifier)")
        c.resume()
        return true
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write("AutoTetherHelper must run as root via launchd\n".data(using: .utf8)!)
    exit(1)
}
guard let teamID = CodeIdentity.teamID else {
    logger.error("helper is not signed with a team identifier; refusing to run")
    exit(1)
}
let controller = SleepController()
controller.ensureAuthorizationRight()
let delegate = ListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.setConnectionCodeSigningRequirement(HelperConstants.requirement(identifier: HelperConstants.appIdentifier, teamID: teamID))
listener.delegate = delegate
listener.resume()
logger.notice("AutoTether helper started (protocol \(HelperConstants.protocolVersion), auth policy \(controller.authorizationPolicyValid ? "ok" : "INVALID", privacy: .public))")
dispatchMain()
