#!/bin/sh
# Build Lua 5.3 interpreters with EdgeTX's number settings (2.11+):
# 32-bit integers, single-precision floats, floats floored when converted to integers.
#   .tools/etxlua53      native build, used by test/run_all.sh to catch radio-only Lua behaviour
#   .tools/etxlua53_m32  32-bit build (needs gcc-multilib): same memory layout and bytecode
#                        format as the radio; build.py uses it for FPVSimBW/core.luac
set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)/.tools
mkdir -p "$DIR"
[ -d "$DIR/lua536" ] || git clone --depth 1 --branch v5.3.6 https://github.com/lua/lua.git "$DIR/lua536"
cd "$DIR/lua536"
SRC="lua.c lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c lobject.c lopcodes.c \
  lparser.c lstate.c lstring.c ltable.c ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c lbitlib.c \
  lcorolib.c ldblib.c liolib.c lmathlib.c loslib.c lstrlib.c ltablib.c lutf8lib.c loadlib.c linit.c"
FLAGS="-O2 -std=gnu99 -DLUA_32BITS -DLUA_FLOORN2I=1 -DLUA_COMPAT_5_2 -DLUA_USE_POSIX"
gcc $FLAGS -o "$DIR/etxlua53" $SRC -lm
echo "built $DIR/etxlua53"
if gcc -m32 $FLAGS -o "$DIR/etxlua53_m32" $SRC -lm 2>/dev/null; then
  echo "built $DIR/etxlua53_m32"
else
  echo "no 32-bit toolchain (apt install gcc-multilib): skipping etxlua53_m32"
fi
