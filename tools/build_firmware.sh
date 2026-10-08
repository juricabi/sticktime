#!/bin/bash
# Build EdgeTX main with firmware/edgetx-fast-lua.patch for one color radio: while a Lua
# tool is open, the UI loop runs every 20 ms instead of 50 ms, each frame goes to the screen
# as soon as it is drawn, and its lines, rectangles and triangles are drawn straight into the
# canvas. On the V12 the Lua interpreter also runs from ITCM and frames go to the screen in
# the background, evenly paced. See README.md, Faster firmware.
#
#   tools/build_firmware.sh v12        (any target name from EdgeTX's tools/build-common.sh)
#
# Needs arm-none-eabi-gcc 14.2 on the PATH (or GCC_ARM=<its bin folder>), cmake, and python3
# with jinja2, pillow, lz4, clang and libclang (EdgeTX's tools/setup_buildenv_ubuntu24.04.sh
# installs all of them). EDGETX_SRC=<checkout> uses an existing EdgeTX checkout.
# The firmware lands in firmware/build/.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:?usage: tools/build_firmware.sh <target, e.g. v12>}
PATCH=$ROOT/firmware/edgetx-fast-lua.patch
SRC=${EDGETX_SRC:-$ROOT/.tools/edgetx-main}
if [ -n "$GCC_ARM" ]; then export PATH=$GCC_ARM:$PATH; fi

if [ ! -d "$SRC/radio" ]; then
  git clone --depth 1 --branch main --recurse-submodules --shallow-submodules \
    https://github.com/EdgeTX/edgetx.git "$SRC"
fi
cd "$SRC"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
elif ! git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "firmware/edgetx-fast-lua.patch does not apply to $SRC" >&2
  exit 1
fi

. tools/build-common.sh
BUILD_OPTIONS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_RULE_MESSAGES=OFF -Wno-dev "
get_target_build_options "$TARGET"
export EDGETX_VERSION_SUFFIX=${EDGETX_VERSION_SUFFIX:-sticktime}   # shown in SYS > Version

mkdir -p "build-$TARGET"
cd "build-$TARGET"
cmake $BUILD_OPTIONS ..
cmake --build . --target arm-none-eabi-configure
cmake --build arm-none-eabi --target firmware-size --parallel "$(nproc)"

OUT=$ROOT/firmware/build
mkdir -p "$OUT"
NAME=edgetx-$TARGET-sticktime-$(git rev-parse --short HEAD)
if [ -f arm-none-eabi/firmware.uf2 ]; then
  cp arm-none-eabi/firmware.uf2 "$OUT/$NAME.uf2"
else
  cp arm-none-eabi/firmware.bin "$OUT/$NAME.bin"
fi
ls -l "$OUT"
