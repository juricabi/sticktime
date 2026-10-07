#!/bin/sh
# Headless regression run of every script variant and screen size under EdgeTX's
# Lua 5.3 settings (build it with tools/build_etxlua.sh). Lua 5.2 (EdgeTX <= 2.10,
# needs `pip install lupa`) runs for two variants, or all of them with FULL=1.
cd "$(dirname "$0")"
LUA53=${LUA53:-../.tools/etxlua53}
S=../sdcard/SCRIPTS/TOOLS
fail=0
check() {
  line=$(echo "$1" | grep -E "^Lua ")
  res=$(echo "$1" | tail -1)
  echo "$line | $res"
  [ "$res" = "ALL OK" ] || fail=1
}
for v in "FPVSim.lua color 480 272" "FPVSim.lua color 480 320" "FPVSim.lua color 320 480" "FPVSim.lua color 320 240" \
         "FPVSim.lua color 800 480" "FPVSimBW.lua bw 128 64" "FPVSimBW.lua bw 212 64"; do
  set -- $v
  check "$($LUA53 harness.lua "$S/$1" $2 $3 $4 2>&1)"
  if [ -n "$FULL" ] || [ "$3" = "480" -a "$4" = "272" ] || [ "$3" = "128" ]; then
    check "$(python3 run52.py "$S/$1" $2 $3 $4 2>&1)"
  fi
done
exit $fail
