import Foundation
import CryptoKit
import Security
import os

let logger = Logger(subsystem: "com.imgold.AutoTether.helper", category: "helper")

@_silgen_name("mbr_uid_to_uuid")
private func mbr_uid_to_uuid(_ uid: uid_t, _ uu: UnsafeMutablePointer<UInt8>) -> Int32

// Consent is stored per account UUID, so a recycled numeric UID doesn't inherit it.
func accountUUID(for uid: uid_t) -> String? {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard mbr_uid_to_uuid(uid, &bytes) == 0 else { return nil }
    let uuid = NSUUID(uuidBytes: bytes).uuidString
    // Synthetic UUIDs are returned for UIDs that have no account record.
    return uuid.hasPrefix("FFFFEEEE-DDDD-CCCC-BBBB-AAAA") ? nil : uuid
}

final class SleepController: @unchecked Sendable {
    private static let dbDirectory = "/private/var/db"
    private static let ownedMarker = "\(dbDirectory)/\(HelperConstants.helperIdentifier).owned"
    private static let consentFile = "\(dbDirectory)/\(HelperConstants.helperIdentifier).consent"
    private static let legacySudoers = "/etc/sudoers.d/autotether"

    private static let expectedRule: [String: Any] = [
        "class": "user", "group": "admin", "shared": false, "timeout": 30,
        "allow-root": false, "authenticate-user": true, "version": 1,
        "comment": "AutoTether: keep the Mac awake with the lid closed",
    ]

    private let queue = DispatchQueue(label: "com.imgold.AutoTether.helper.sleep")
    private var holders: [ObjectIdentifier: String] = [:]
    private var consented = Set<String>()
    // Bumped on every revoke so a grant that was verified before it can't be persisted after it.
    private var revocations: [String: Int] = [:]
    private var retryingRestore = false
    private var usedAuthorizations: [Data: Date] = [:]
    private var owned = false
    private var upgrading = false

    init() {
        queue.sync {
            consented = Self.loadConsent()
            owned = FileManager.default.fileExists(atPath: Self.ownedMarker)
            if owned {
                logger.notice("found ownership marker from a previous run; restoring")
                _ = restoreOrRetryLocked()
            }
        }
    }

    // MARK: - pmset

    private func pmset(_ args: [String]) -> Shell.Result {
        let result = Shell.runSync("/usr/bin/pmset", args, timeout: HelperConstants.pmsetTimeout)
        if result.timedOut { logger.error("pmset timed out: \(args.joined(separator: " "), privacy: .public)") }
        return result
    }

    private func readState() -> Int {
        let result = pmset(["-g"])
        guard result.ok else { return -1 }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "1": return 1
            case "0": return 0
            default: return -1
            }
        }
        return -1
    }

    // MARK: - Durable files

    private static func syncDirectory() -> Bool {
        let fd = open(dbDirectory, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    private static func atomicWrite(_ text: String, to path: String) -> Bool {
        let temp = "\(path).tmp.\(getpid())"
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            logger.error("open \(temp, privacy: .public) failed: \(errno)")
            return false
        }
        let written = writeAll(fd, Array(text.utf8)) && fsync(fd) == 0
        let error = errno
        close(fd)
        guard written, rename(temp, path) == 0 else {
            logger.error("write \(path, privacy: .public) failed: \(error)")
            unlink(temp)
            return false
        }
        guard syncDirectory() else {
            logger.error("fsync of \(dbDirectory, privacy: .public) failed: \(errno)")
            return false
        }
        return true
    }

    private static func remove(_ path: String) -> Bool {
        guard unlink(path) == 0 || errno == ENOENT else { return false }
        return syncDirectory()
    }

    private func setOwned(_ value: Bool) -> Bool {
        let ok = value ? Self.atomicWrite("1\n", to: Self.ownedMarker) : Self.remove(Self.ownedMarker)
        if ok { owned = value }
        return ok
    }

    // Without holders nobody will ask again, so keep trying in the background.
    private func scheduleRestoreRetry(after delay: TimeInterval = 5) {
        guard !retryingRestore else { return }
        retryingRestore = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            retryingRestore = false
            guard owned, holders.isEmpty else { return }
            if !restoreLocked() { scheduleRestoreRetry(after: min(delay * 2, 300)) }
        }
    }

    private func restoreOrRetryLocked() -> Bool {
        let ok = restoreLocked()
        if !ok && holders.isEmpty { scheduleRestoreRetry() }
        return ok
    }

    private func restoreLocked() -> Bool {
        guard owned else { return true }
        for attempt in 1...3 {
            _ = pmset(["-a", "disablesleep", "0"])
            if readState() == 0 {
                guard setOwned(false) || setOwned(false) else {
                    logger.error("sleep restored but the ownership marker could not be removed")
                    return false
                }
                logger.notice("sleep restored (attempt \(attempt))")
                return true
            }
            usleep(500_000)
        }
        logger.error("failed to restore sleep")
        return false
    }

    // MARK: - Consent

    private static func loadConsent() -> Set<String> {
        let fd = open(consentFile, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_size < 65_536,
              let data = try? handle.readToEnd() else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Set(lines.filter { UUID(uuidString: $0) != nil })
    }

    private static func saveConsent(_ accounts: Set<String>) -> Bool {
        accounts.isEmpty ? remove(consentFile) : atomicWrite(accounts.sorted().joined(separator: "\n") + "\n", to: consentFile)
    }

    // authd adds bookkeeping keys (created, identifier, requirement...). Anything else, such as
    // session-owner, entitled or a delegated rule, could weaken the admin check.
    private static let allowedRuleKeys: Set<String> = [
        "class", "group", "shared", "timeout", "allow-root", "authenticate-user", "session-owner", "tries",
        "version", "comment", "created", "modified", "identifier", "requirement", "default-prompt", "default-button",
    ]

    private static func ruleIsValid() -> Bool {
        var definition: CFDictionary?
        guard AuthorizationRightGet(HelperConstants.authorizationRight, &definition) == errAuthorizationSuccess,
              let rule = definition as? [String: Any],
              Set(rule.keys).isSubset(of: allowedRuleKeys) else { return false }
        guard let timeoutValue = rule["timeout"] as CFTypeRef?, CFGetTypeID(timeoutValue) == CFNumberGetTypeID(),
              let timeout = (timeoutValue as? NSNumber)?.intValue else { return false }
        return rule["class"] as? String == "user"
            && rule["group"] as? String == "admin"
            && rule["shared"] as? Bool == false
            && (rule["allow-root"] as? Bool ?? false) == false
            && (rule["session-owner"] as? Bool ?? false) == false
            && (rule["authenticate-user"] as? Bool ?? true) == true
            && (1...30).contains(timeout)
    }

    func installAuthorizationRight() {
        guard !Self.ruleIsValid() else { return }
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return }
        defer { AuthorizationFree(auth, []) }
        let status = AuthorizationRightSet(auth, HelperConstants.authorizationRight, Self.expectedRule as CFDictionary,
                                           "AutoTether가 덮개를 닫아도 Mac이 잠자기하지 않도록 설정하려고 합니다." as CFString,
                                           nil, nil)
        logger.notice("authorization right registered: \(status)")
    }

    func grantConsent(_ data: Data, account: String?) -> (Bool, String) {
        guard let account else { return (false, "unknown account") }
        // Checked on every grant, not just at startup, in case the rule was changed.
        guard Self.ruleIsValid() else { return (false, "authorization rule has an unexpected policy") }
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return (false, "invalid authorization") }

        let digest = Data(SHA256.hash(data: data))
        let generation = queue.sync { revocations[account, default: 0] }

        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { data.copyBytes(to: $0) }
        var auth: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &auth) == errAuthorizationSuccess, let auth else {
            return (false, "authorization not usable")
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        let status = HelperConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(auth, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            logger.notice("consent rejected: \(status)")
            return (false, "authorization denied (\(status))")
        }

        return queue.sync {
            // Only verified forms are recorded, so junk requests can't fill this. Rights expire after 30 s.
            let now = Date()
            usedAuthorizations = usedAuthorizations.filter { now.timeIntervalSince($0.value) < 300 }
            guard usedAuthorizations.updateValue(now, forKey: digest) == nil else { return (false, "authorization already used") }
            guard revocations[account, default: 0] == generation else { return (false, "revoked during verification") }
            guard Self.ruleIsValid() else { return (false, "authorization rule changed during verification") }
            var updated = consented
            updated.insert(account)
            guard Self.saveConsent(updated) else {
                // The rename may already be on disk; put the previous set back so a restart doesn't load it.
                _ = Self.saveConsent(consented)
                return (false, "consent could not be saved")
            }
            consented = updated
            logger.notice("consent granted")
            return (true, "granted")
        }
    }

    func revokeConsent(account: String?) -> Bool {
        guard let account else { return false }
        return queue.sync {
            // Stop honoring consent in memory first, even if persisting the change fails.
            // Persist before the slow restore so a crash during pmset can't bring the consent back.
            revocations[account, default: 0] += 1
            consented.remove(account)
            let saved = Self.saveConsent(consented)
            holders = holders.filter { $0.value != account }
            let restored = holders.isEmpty ? restoreOrRetryLocked() : true
            return saved && restored
        }
    }

    // MARK: - Requests

    func status(account: String?) -> (state: Int, owned: Bool, consented: Bool) {
        queue.sync { (readState(), owned, account.map(consented.contains) ?? false) }
    }

    func setSleepDisabled(_ on: Bool, adopt: Bool, client: ObjectIdentifier, account: String?) -> (Bool, Int, String) {
        queue.sync {
            guard on else {
                holders.removeValue(forKey: client)
                guard holders.isEmpty, owned else {
                    return (true, readState(), owned ? "other holders remain" : "not owned")
                }
                let ok = restoreOrRetryLocked()
                return (ok, readState(), ok ? "restored" : "restore failed")
            }

            guard !upgrading else { return (false, readState(), "upgrading") }
            guard let account, consented.contains(account) else { return (false, readState(), "consent required") }

            switch readState() {
            case 1:
                // Only take over an existing setting when migrating from the sudoers-based version.
                let migrating = adopt && FileManager.default.fileExists(atPath: Self.legacySudoers)
                guard owned || migrating else { return (true, 1, "already on, not owned") }
                if !owned {
                    guard setOwned(true) else { return (false, 1, "cannot record ownership") }
                    logger.notice("adopted existing setting")
                }
                holders[client] = account
                return (true, 1, "already on")
            case 0:
                guard setOwned(true) else { return (false, 0, "cannot record ownership") }
                holders[client] = account
                _ = pmset(["-a", "disablesleep", "1"])
                if readState() == 1 {
                    logger.notice("sleep disabled")
                    return (true, 1, "enabled")
                }
                holders.removeValue(forKey: client)
                _ = restoreOrRetryLocked()
                return (false, readState(), "pmset failed")
            default:
                return (false, -1, "state unknown")
            }
        }
    }

    func clientDisconnected(_ client: ObjectIdentifier) {
        queue.sync {
            guard holders.removeValue(forKey: client) != nil, holders.isEmpty, owned else { return }
            logger.notice("last holder disconnected; restoring")
            _ = restoreOrRetryLocked()
        }
    }

    func prepareForUpgrade() -> Bool {
        queue.sync {
            upgrading = true
            guard restoreLocked() else {
                upgrading = false
                return false
            }
            holders.removeAll()
            return true
        }
    }

    func removeLegacySudoers() -> Bool {
        queue.sync {
            var info = stat()
            guard lstat(Self.legacySudoers, &info) == 0 else { return errno == ENOENT }
            guard info.st_mode & S_IFMT == S_IFREG, unlink(Self.legacySudoers) == 0 else { return false }
            logger.notice("removed legacy sudoers rule")
            return true
        }
    }
}

final class HelperService: NSObject, AutoTetherHelperProtocol {
    private let controller: SleepController
    private let client: ObjectIdentifier
    private let account: String?

    init(controller: SleepController, connection: NSXPCConnection) {
        self.controller = controller
        client = ObjectIdentifier(connection)
        account = accountUUID(for: connection.effectiveUserIdentifier)
    }

    func status(reply: @escaping (Int, Bool, Int, Bool) -> Void) {
        let status = controller.status(account: account)
        reply(status.state, status.owned, HelperConstants.protocolVersion, status.consented)
    }

    func grantConsent(_ authorization: Data, reply: @escaping (Bool, String) -> Void) {
        let (ok, message) = controller.grantConsent(authorization, account: account)
        reply(ok, message)
    }

    func revokeConsent(reply: @escaping (Bool) -> Void) {
        reply(controller.revokeConsent(account: account))
    }

    func setSleepDisabled(_ on: Bool, adoptExisting: Bool, reply: @escaping (Bool, Int, String) -> Void) {
        let (ok, state, message) = controller.setSleepDisabled(on, adopt: adoptExisting, client: client, account: account)
        reply(ok, state, message)
    }

    func removeLegacySudoers(reply: @escaping (Bool) -> Void) {
        reply(controller.removeLegacySudoers())
    }

    func prepareForUpgrade(reply: @escaping (Bool) -> Void) {
        let ok = controller.prepareForUpgrade()
        reply(ok)
        if ok {
            logger.notice("exiting for upgrade")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let controller: SleepController

    init(controller: SleepController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: AutoTetherHelperProtocol.self)
        connection.exportedObject = HelperService(controller: controller, connection: connection)
        connection.invalidationHandler = { [controller] in controller.clientDisconnected(id) }
        connection.interruptionHandler = { [controller] in controller.clientDisconnected(id) }
        connection.resume()
        return true
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("AutoTetherHelper must be started by launchd\n".utf8))
    exit(1)
}
guard let teamID = CodeIdentity.teamID else {
    logger.error("helper is not signed with a team identifier")
    exit(1)
}

let controller = SleepController()
controller.installAuthorizationRight()
let delegate = ListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.setConnectionCodeSigningRequirement(
    HelperConstants.requirement(identifier: HelperConstants.appIdentifier, teamID: teamID))
listener.delegate = delegate
listener.resume()
logger.notice("helper started (protocol \(HelperConstants.protocolVersion))")
dispatchMain()
