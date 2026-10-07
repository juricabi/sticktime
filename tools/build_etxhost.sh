#!/bin/sh
# Build .tools/etxhost: EdgeTX's own Lua 5.3 (from the EdgeTX repository) as a 32-bit host
# program with a model of the B&W radios' Lua memory (see tools/etxhost/host.c).
# Needs gcc-multilib. Set EDGETX_SRC to an EdgeTX checkout to skip the download.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/.tools
mkdir -p "$DIR"
SRC=${EDGETX_SRC:-$DIR/edgetx}
if [ ! -d "$SRC/radio/src/thirdparty/Lua/src" ]; then
  git clone --depth 1 --filter=blob:none --sparse https://github.com/EdgeTX/edgetx.git "$SRC"
  (cd "$SRC" && git sparse-checkout set radio/src/thirdparty/Lua)
fi
L=$SRC/radio/src/thirdparty/Lua/src
CORE="lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c lobject.c lopcodes.c lparser.c
  lstate.c lstring.c ltable.c ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c lstrlib.c lmathlib.c lbitlib.c
  ltablib.c ldblib.c"
FILES=""
for f in $CORE; do FILES="$FILES $L/$f"; done
gcc -m32 -O2 -std=gnu99 -w -DLUA_HOST_BUILD -DLUA_CROSS_COMPILER -DLUA_COMPAT_5_2 -I"$L" \
  -o "$DIR/etxhost" "$ROOT/tools/etxhost/host.c" $FILES -lm
echo "built $DIR/etxhost"
