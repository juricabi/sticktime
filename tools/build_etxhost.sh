#!/bin/sh
# Build .tools/etxhost: EdgeTX's own Lua 5.3 (from the EdgeTX repository) as a 32-bit host
# program with a model of the B&W radios' Lua memory (see tools/etxhost/host.c).
# Needs gcc-multilib. Set EDGETX_SRC to an EdgeTX checkout to skip the download.
#   tools/build_etxhost.sh            EdgeTX main         -> .tools/etxhost
#   tools/build_etxhost.sh v2.11.4    a release's Lua     -> .tools/etxhost-v2.11.4
# 2.11's Lua keeps a whole int for each value's type tag, where main packs it into a byte, so
# the same script needs about 10% more memory there: test/run_all.sh checks both.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/.tools
mkdir -p "$DIR/stub"
REF=$1
if [ -n "$REF" ]; then
  SRC=$DIR/edgetx-$REF
  OUT=$DIR/etxhost-$REF
else
  SRC=${EDGETX_SRC:-$DIR/edgetx}
  OUT=$DIR/etxhost
fi
if [ ! -d "$SRC/radio/src/thirdparty/Lua/src" ]; then
  git clone --depth 1 --filter=blob:none --sparse ${REF:+--branch "$REF"} https://github.com/EdgeTX/edgetx.git "$SRC"
  (cd "$SRC" && git sparse-checkout set radio/src/thirdparty/Lua)
fi
# 2.11's luaconf.h includes the firmware's debug.h even in a host build
printf '#pragma once\n#include <stdio.h>\n#define TRACE_DEBUG_WP(...) fprintf(stderr, __VA_ARGS__)\n' > "$DIR/stub/debug.h"
L=$SRC/radio/src/thirdparty/Lua/src
CORE="lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c lobject.c lopcodes.c lparser.c
  lstate.c lstring.c ltable.c ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c lstrlib.c lmathlib.c lbitlib.c
  ltablib.c ldblib.c"
FILES=""
for f in $CORE; do FILES="$FILES $L/$f"; done
gcc -m32 -O2 -std=gnu99 -w -DLUA_HOST_BUILD -DLUA_CROSS_COMPILER -DLUA_COMPAT_5_2 -I"$L" -I"$DIR/stub" \
  -o "$OUT" "$ROOT/tools/etxhost/host.c" $FILES -lm
echo "built $OUT"
