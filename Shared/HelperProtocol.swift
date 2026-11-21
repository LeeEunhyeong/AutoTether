import Foundation

/// 앱(AutoTether) ↔ 권한 헬퍼(root LaunchDaemon) 공용 정의.
/// 헬퍼는 "덮개 닫힘 잠자기 방지(pmset disablesleep)" 한 가지 일만 한다.
enum HelperConstants {
    static let machService = "com.imgold.AutoTether.helper"
    static let plistName = "com.imgold.AutoTether.helper.plist"
    static let protocolVersion = 2

    /// 잠자기 방지를 켤 때 사용자가 macOS 인증(Touch ID 또는 관리자 암호)으로 받아야 하는 권한 이름
    static let authorizationRight = "com.imgold.AutoTether.preventLidSleep"

    static let appIdentifier = "com.imgold.AutoTether"
    static let helperIdentifier = "com.imgold.AutoTether.helper"

    /// 서명 요구 사항. 팀 ID는 실행 중인 자기 자신의 서명에서 읽음
    /// (소스를 받아 자기 팀으로 빌드한 사람도 코드 수정 없이 동작. 서명이 없으면 사용 안 함).
    static func requirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// state: -1 = 확인 불가, 0 = macOS 기본, 1 = 잠자기 비활성
@objc protocol AutoTetherHelperProtocol {
    /// 현재 상태, 헬퍼가 켠 것인지(소유), 프로토콜 버전, 이 사용자가 인증으로 동의했는지
    func status(reply: @escaping (_ state: Int, _ owned: Bool, _ version: Int, _ consented: Bool) -> Void)

    /// 사용자가 macOS 인증으로 얻은 권한(AuthorizationExternalForm)을 제출 → 헬퍼가 직접 검증 후 동의 기록
    func grantConsent(_ authorization: Data, reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// 동의 철회 (잠자기 방지 끄기·헬퍼 제거 시). 헬퍼가 켠 상태였다면 복구.
    func revokeConsent(reply: @escaping (_ ok: Bool) -> Void)

    /// on=true: 동의가 있을 때만 잠자기 방지를 켜고 이 연결을 '보유자'로 등록.
    ///          연결이 끊기면(앱 종료·크래시) 헬퍼가 자동 복구.
    /// adoptExisting: 이미 켜져 있을 때 소유권을 넘겨받을지 (예전 버전이 켠 상태 이전용)
    /// on=false: 보유자 해제. 남은 보유자가 없고 헬퍼가 켠 경우에만 끔 (다른 도구가 켠 설정은 건드리지 않음)
    func setSleepDisabled(_ on: Bool, adoptExisting: Bool,
                          reply: @escaping (_ ok: Bool, _ state: Int, _ message: String) -> Void)

    /// 예전 버전이 설치한 /etc/sudoers.d/autotether 제거 (계정 전체에 주던 권한 회수)
    func removeLegacySudoers(reply: @escaping (_ removed: Bool) -> Void)

    /// 앱 업데이트 후 새 헬퍼로 교체: 보유자가 없으면 종료(launchd가 다음 요청 때 새 바이너리로 실행)
    func prepareForUpgrade(reply: @escaping (_ willExit: Bool) -> Void)
}
