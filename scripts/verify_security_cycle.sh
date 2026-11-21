#!/bin/bash
# 보안 강화 후 실제 네트워크 시험 (실패 시 0이 아닌 종료 코드)
#  1) 학습 기록 없이 자동 전환 → 기본 WPA3(SAE) 필수 정책으로 연결돼야 함
#  2) 수동 연결 + 복귀
#  각 단계 후 지정한 집 Wi-Fi(HOME_SSID)로 실제 복귀했는지 SSID로 확인
cd ~/Developer/AutoTether
: "${HOME_SSID:?HOME_SSID 지정 필요 (공백 구분 여러 개 가능, 첫 번째가 복구 대상)}"
is_home() { for h in $HOME_SSID; do [ "$1" = "$h" ] && return 0; done; return 1; }
PRIMARY_HOME=${HOME_SSID%% *}
APP=build/Build/Products/Debug/AutoTether.app/Contents/MacOS/AutoTether
LOG=~/Library/Logs/AutoTether.log
FAIL=0

current_ssid() { $APP --status 2>/dev/null | sed -n 's/.* ssid=\(.*\)$/\1/p' | head -1; }
restore() {
  local s; s=$(current_ssid)
  local i=0
  while ! is_home "$s" && [ $i -lt 3 ]; do
    networksetup -setairportnetwork en0 "$PRIMARY_HOME" >/dev/null 2>&1; sleep 10; s=$(current_ssid); i=$((i+1))
  done
  if is_home "$s"; then echo "  [restore] OK ($s)"; else echo "  [restore] FAIL (현재: ${s:-없음})"; FAIL=1; fi
}
step() {  # $1=설명, 나머지=명령
  local desc=$1; shift
  echo "== $desc"
  "$@" 2>/dev/null; local rc=$?
  if [ $rc -eq 0 ]; then echo "  -> PASS"; else echo "  -> FAIL (exit $rc)"; FAIL=1; fi
  restore
  sleep 3
}

L=$(wc -l < $LOG)
# 운영 보안 학습값 백업 → 시험 후 복원 (시험이 사용자 설정을 바꾸지 않도록)
BACKUP_WPA3=$(defaults export com.imgold.AutoTether - | plutil -extract hotspotWPA3 xml1 -o - - 2>/dev/null)
restore_wpa3() {
  if [ -n "$BACKUP_WPA3" ]; then
    python3 - "$BACKUP_WPA3" <<'PY'
import plistlib, subprocess, sys
d = plistlib.loads(subprocess.run(["defaults","export","com.imgold.AutoTether","-"],capture_output=True).stdout)
d["hotspotWPA3"] = plistlib.loads(sys.argv[1].encode())
subprocess.run(["defaults","import","com.imgold.AutoTether","-"], input=plistlib.dumps(d), check=True)
PY
  else
    defaults delete com.imgold.AutoTether hotspotWPA3 2>/dev/null
  fi
}
trap restore_wpa3 EXIT
defaults delete com.imgold.AutoTether hotspotWPA3 2>/dev/null
step "1) 학습 없이 자동 전환 (기본 WPA3 필수)" $APP --test-failover
step "2) 수동 연결 + 복귀" $APP --test-connect "${DEVICE:?DEVICE 환경변수(핫스팟 기기 이름) 지정 필요}" --and-return
echo "== 학습된 보안 정책: $(defaults export com.imgold.AutoTether - | plutil -extract hotspotWPA3 json -o - - 2>/dev/null)"
echo "== 앱 로그"
tail -n +$((L+1)) $LOG | grep -v "주변 기기 발견\|AutoTether 시작"
echo "== 결과: $([ $FAIL -eq 0 ] && echo 전체 통과 || echo 실패 있음)"
exit $FAIL
