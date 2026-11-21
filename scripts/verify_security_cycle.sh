#!/bin/bash
# Real-device check: automatic failover (WPA3 required), then manual connect + return.
# Usage: HOME_SSID="Home_5G Home_2.4G" DEVICE="My iPhone" scripts/verify_security_cycle.sh
cd "$(dirname "$0")/.." || exit 1
: "${HOME_SSID:?set HOME_SSID (space separated; the first one is restored)}"
: "${DEVICE:?set DEVICE (hotspot device name)}"

APP=build/Build/Products/Debug/AutoTether.app/Contents/MacOS/AutoTether
LOG=~/Library/Logs/AutoTether.log
DOMAIN=com.imgold.AutoTether
FAIL=0

is_home() { for h in $HOME_SSID; do [ "$1" = "$h" ] && return 0; done; return 1; }
current_ssid() { $APP --status 2>/dev/null | sed -n 's/.* ssid=\(.*\)$/\1/p' | head -1; }

restore_wifi() {
  local s i=0
  s=$(current_ssid)
  while ! is_home "$s" && [ $i -lt 3 ]; do
    networksetup -setairportnetwork en0 "${HOME_SSID%% *}" >/dev/null 2>&1
    sleep 10
    s=$(current_ssid)
    i=$((i + 1))
  done
  if is_home "$s"; then echo "  restore OK ($s)"; else echo "  restore FAIL (now: ${s:-none})"; FAIL=1; fi
}

step() {
  echo "== $1"
  shift
  if "$@" 2>/dev/null; then echo "  PASS"; else echo "  FAIL ($?)"; FAIL=1; fi
  restore_wifi
  sleep 3
}

# The test clears learned WPA3 state; put the user's value back afterwards.
SAVED=$(defaults export $DOMAIN - | plutil -extract hotspotWPA3 xml1 -o - - 2>/dev/null)
restore_settings() {
  if [ -z "$SAVED" ]; then
    defaults delete $DOMAIN hotspotWPA3 2>/dev/null
    return
  fi
  python3 - "$SAVED" <<'PY'
import plistlib, subprocess, sys
d = plistlib.loads(subprocess.run(["defaults", "export", "com.imgold.AutoTether", "-"], capture_output=True).stdout)
d["hotspotWPA3"] = plistlib.loads(sys.argv[1].encode())
subprocess.run(["defaults", "import", "com.imgold.AutoTether", "-"], input=plistlib.dumps(d), check=True)
PY
}
trap restore_settings EXIT

START=$(wc -l < $LOG)
defaults delete $DOMAIN hotspotWPA3 2>/dev/null
step "automatic failover, nothing learned (WPA3 required)" $APP --test-failover
step "manual connect + return" $APP --test-connect "$DEVICE" --and-return

echo "== log"
tail -n +$((START + 1)) $LOG | grep -v "주변 기기 발견\|AutoTether 시작"
[ $FAIL -eq 0 ] && echo "== all passed" || echo "== failed"
exit $FAIL
