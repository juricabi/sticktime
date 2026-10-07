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
         "FPVSim.lua color 800 480" "FPVSimBW/core.lua bw 128 64" "FPVSimBW/core.lua bw 212 64"; do
  set -- $v
  check "$($LUA53 harness.lua "$S/$1" $2 $3 $4 2>&1)"
  if [ -n "$FULL" ] || [ "$3" = "480" -a "$4" = "272" ] || [ "$3" = "128" ]; then
    check "$(python3 run52.py "$S/$1" $2 $3 $4 2>&1)"
  fi
done
# faster firmware: run() every 20 ms and 16 ms instead of 50 ms
for ms in 20 16; do
  out=$(FRAME_MS=$ms $LUA53 harness.lua "$S/FPVSim.lua" color 480 272 2>&1)
  echo "$(echo "$out" | grep -E "^Lua " | sed "s/frames/@$ms ms  frames/") | $(echo "$out" | tail -1)"
  [ "$(echo "$out" | tail -1)" = "ALL OK" ] || fail=1
done
# draw order of the Bando's walls, tower and containers (ray-cast check over random camera poses)
for v in "480 272" "320 480" "800 480"; do
  set -- $v
  out=$($LUA53 order_check.lua "$S/FPVSim.lua" color $1 $2 2>&1)
  echo "order $1x$2: $(echo "$out" | grep -o 'separating planes [0-9]* wrong pairs') | $(echo "$out" | tail -1)"
  [ "$(echo "$out" | tail -1)" = "ALL OK" ] || fail=1
done
# FPV Sim Lite (the build with test hooks): 128x64 and 212x64, and Lua 5.2
lite() {
  echo "$(echo "$1" | grep -E "^Lua ") | $(echo "$1" | tail -1)"
  [ "$(echo "$1" | tail -1)" = "ALL OK" ] || fail=1
}
lite "$($LUA53 lite_test.lua build/fpvlite_test.lua 128 64 2>&1)"
lite "$($LUA53 lite_test.lua build/fpvlite_test.lua 212 64 2>&1)"
lite "$(python3 run52.py build/fpvlite_test.lua lite 128 64 lite_test.lua 2>&1)"
# the B&W loaders and the precompiled bytecode (32-bit EdgeTX-config Lua)
if [ -x ../.tools/etxlua53_m32 ]; then
  out=$(../.tools/etxlua53_m32 loader_test.lua 2>&1) && echo "$out" | tail -1 || { echo "$out"; fail=1; }
fi
# memory on EdgeTX's own Lua with the radio's allocator (tools/build_etxhost.sh), through the
# loaders as shipped: the Lite on an STM32F2 X9D+ (63.3 KB heap), the full B&W game on an
# STM32F4 X9D+ 2019 (113.6 KB heap + 34 KB CCM), the smallest heaps of each kind
if [ -x ../.tools/etxhost ]; then
  mem() {
    echo "memory $1: $(echo "$2" | head -1 | sed 's/^.*TOOLS\///') | $(echo "$2" | tail -1)"
    [ "$(echo "$2" | tail -1)" = "MEM OK" ] || fail=1
  }
  for wh in "128 64" "212 64"; do
    set -- $wh
    mem F2 "$(ETX_MODEL=f2 ETX_HEAP=63300 ../.tools/etxhost -radio memtest.lua "$S/FPVLite.lua" $1 $2 2>&1)"
    mem F4 "$(ETX_MODEL=f4 ETX_HEAP=113600 ETX_CCM=34816 ../.tools/etxhost -radio memtest.lua "$S/FPVSimBW.lua" $1 $2 2>&1)"
  done
fi
exit $fail
