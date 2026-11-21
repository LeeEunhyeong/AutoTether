#!/bin/bash
# 전체 사이클 검증: 앱 집계 vs 실제 en0 카운터 비교
cd ~/Developer/AutoTether
: "${HOME_SSID:?HOME_SSID 환경변수(복귀할 집 Wi-Fi 이름)를 지정하세요}"
D=~/.hermes/profiles/mac_dev/cache/scratch
W=$D/watch.txt; : > "$W"
DB="$HOME/Library/Application Support/AutoTether/usage.sqlite"
B0=$(sqlite3 "$DB" "select coalesce(sum(rx+tx),0) from usage")

watch() {
  for i in $(seq 1 100); do
    f=$(scutil --nwi | grep -m1 "en0 :" | grep -c CLAT46)
    r=$(netstat -ibn | awk '$1=="en0" && $3 ~ /Link/ {print $7+$10; exit}')
    echo "$(date +%s) $f $r" >> "$W"
    sleep 1
  done
}
watch &
WP=$!
sleep 2
build/Build/Products/Debug/AutoTether.app/Contents/MacOS/AutoTether --test-connect "${DEVICE:?DEVICE 환경변수(핫스팟 기기 이름) 지정 필요}" --and-return > $D/cycle2.txt 2>/dev/null
echo "exit=$?" >> $D/cycle2.txt
sleep 4
kill $WP 2>/dev/null
if ! curl -s -m 5 https://captive.apple.com/hotspot-detect.html | grep -q Success; then
  networksetup -setairportnetwork en0 "${HOME_SSID:?HOME_SSID 환경변수를 지정하세요}" >/dev/null 2>&1; sleep 8
fi
B1=$(sqlite3 "$DB" "select coalesce(sum(rx+tx),0) from usage")
cat $D/cycle2.txt
echo "app DB delta (rx+tx) = $((B1-B0)) bytes"
python3 - "$W" <<'EOF'
import sys
rows=[l.split() for l in open(sys.argv[1]) if len(l.split())==3]
rows=[(int(t),int(f),int(b)) for t,f,b in rows]
tot=0; secs=0
for (t0,f0,b0),(t1,f1,b1) in zip(rows,rows[1:]):
    if f0==1 and f1==1: tot+=b1-b0; secs+=t1-t0
print(f"watcher: hotspot(CLAT46) seconds={secs}, real en0 bytes on hotspot={tot}")
print("max 1s delta overall:", max(b1-b0 for (_,_,b0),(_,_,b1) in zip(rows,rows[1:])))
EOF
scutil --nwi | grep -A1 "en0 :" | head -2
