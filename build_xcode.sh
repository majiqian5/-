#!/bin/bash
# build_xcode.sh — 在 macOS 上用 Apple clang 编译 AxsLevel（v2）
#
# 为什么必须在 Mac 上：
#   mediaserverd 是 arm64e，dylib 必须是 arm64e + ABI v2（指针认证 PAC）。
#   Linux 的 clang/Theos 能打出 -target arm64e，但不生成 ptrauth 指令，
#   产物 cpusubtype 是 0x2 而非 0x80000002，手动改 Mach-O 头虽然能骗过 dlopen，
#   但一调用 MSHookFunction / pthread_create 就触发指针认证失败，进程立即死。
#   只有 Apple clang 会输出正确的 ABI v2 代码。
#
# 用法：
#   ./build_xcode.sh            # arm64e + arm64 双 slice，产物在 ./out/
#   ./build_xcode.sh --arm64e-only   # 只出 arm64e（A12 及以上设备）
#
set -euo pipefail

ONLY_E=0
[ "${1:-}" = "--arm64e-only" ] && ONLY_E=1

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC_DIR/out"
mkdir -p "$OUT"

IOS_MIN=15.0
INSTALL_NAME=/var/jb/Library/AxsEQ/AxsLevel.dylib

# ---------------------------------------------------------------- 环境自检
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  echo "✗ xcode-select 没指向完整 Xcode（CommandLineTools 不带 iphoneos SDK）"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

if ! SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null); then
  echo "✗ 取不到 iphoneos SDK"
  exit 1
fi

CLANG=$(xcrun --sdk iphoneos --find clang)
CVER=$("$CLANG" --version | head -1)
echo "== 工具链 =="
echo "   $CVER"
echo "   SDK: $SDK"

case "$CVER" in
  *"Apple clang"*) : ;;
  *) echo "✗ 这不是 Apple clang，产物不会有 PAC"; exit 1 ;;
esac

# ---------------------------------------------------------------- 编译
CFLAGS=(
  -isysroot "$SDK"
  -O2 -fobjc-arc
  -Wall -Wextra
  -Wno-unused-parameter
  -fno-common
)

build_slice () {   # $1=arch  $2=out
  local arch="$1" out="$2"
  echo "== 编译 $arch =="
  "$CLANG" -target "${arch}-apple-ios${IOS_MIN}" "${CFLAGS[@]}" \
    -dynamiclib \
    -framework Foundation -framework AudioToolbox \
    -install_name "$INSTALL_NAME" \
    -compatibility_version 2.0 -current_version 2.0 \
    -Wl,-dead_strip \
    -o "$out" "$SRC_DIR/AxsLevel.m"
}

SLICES=()
if [ "$ONLY_E" -eq 1 ]; then
  build_slice arm64e "$OUT/AxsLevel.arm64e.dylib"
  SLICES+=("$OUT/AxsLevel.arm64e.dylib")
else
  build_slice arm64e "$OUT/AxsLevel.arm64e.dylib"
  build_slice arm64  "$OUT/AxsLevel.arm64.dylib"
  SLICES+=("$OUT/AxsLevel.arm64e.dylib" "$OUT/AxsLevel.arm64.dylib")
fi

rm -f "$OUT/AxsLevel.dylib"
lipo -create "${SLICES[@]}" -output "$OUT/AxsLevel.dylib"
echo "== 已合并 $(lipo -info "$OUT/AxsLevel.dylib") =="

# axs_lv：设备上的自测小工具，同样要双 slice
LV_SLICES=()
for arch in arm64e$([ "$ONLY_E" -eq 1 ] || echo " arm64"); do
  echo "== 编译 axs_lv ($arch) =="
  "$CLANG" -target "${arch}-apple-ios${IOS_MIN}" -isysroot "$SDK" -O2 \
    -o "$OUT/axs_lv.$arch" "$SRC_DIR/axs_lv.c"
  LV_SLICES+=("$OUT/axs_lv.$arch")
done
rm -f "$OUT/axs_lv"
lipo -create "${LV_SLICES[@]}" -output "$OUT/axs_lv"

# 面板侧源码只做语法确认，不进产物
echo "== 语法检查 AxsTcpLevels.m =="
"$CLANG" -target arm64e-apple-ios${IOS_MIN} -isysroot "$SDK" -fobjc-arc \
  -fsyntax-only -framework Foundation "$SRC_DIR/AxsTcpLevels.m"

# ---------------------------------------------------------------- 签名（必须 ldid）
if ! command -v ldid >/dev/null; then
  echo "✗ 没装 ldid。codesign 的 ad-hoc 签名在设备上会被 AMFI 拒，dlopen 直接失败。"
  echo "  装：brew install ldid-procursus   （或 xpwn 的 ldid）"
  exit 1
fi

echo "== ldid 签名 =="
ldid -S"$SRC_DIR/ent.plist" "$OUT/AxsLevel.dylib"
ldid -S"$SRC_DIR/ent.plist" "$OUT/axs_lv"

chmod +x "$OUT/axs_lv"

# ---------------------------------------------------------------- 产物自证
echo
"$SRC_DIR/verify.sh" "$OUT"
