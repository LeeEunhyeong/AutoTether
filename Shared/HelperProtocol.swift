import Foundation

enum HelperConstants {
    static let machService = "com.imgold.AutoTether.helper"
    static let plistName = "com.imgold.AutoTether.helper.plist"
    static let appIdentifier = "com.imgold.AutoTether"
    static let helperIdentifier = "com.imgold.AutoTether.helper"
    static let authorizationRight = "com.imgold.AutoTether.preventLidSleep"
    static let protocolVersion = 7
    static let pmsetTimeout: Double = 8
    // Worst case on the helper's queue: a failed enable runs up to ten pmset calls, each up to
    // timeout + 6 s of cleanup.
    static let replyTimeout: Double = 150

    static func requirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

// state: -1 unknown, 0 normal, 1 sleep disabled
@objc protocol AutoTetherHelperProtocol {
    func status(reply: @escaping (_ state: Int, _ owned: Bool, _ version: Int, _ consented: Bool) -> Void)
    func grantConsent(_ authorization: Data, reply: @escaping (_ ok: Bool, _ message: String) -> Void)
    func revokeConsent(reply: @escaping (_ ok: Bool) -> Void)
    func setSleepDisabled(_ on: Bool, adoptExisting: Bool,
                          reply: @escaping (_ ok: Bool, _ state: Int, _ message: String) -> Void)
    func removeLegacySudoers(reply: @escaping (_ removed: Bool) -> Void)
    func prepareForUpgrade(reply: @escaping (_ willExit: Bool) -> Void)
}
