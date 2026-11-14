#!/bin/bash
# verify.sh — 编译产物自证（在 macOS 上跑）
# 用法：./verify.sh [out目录]
#
# 这个脚本回答一个问题：我手里的 AxsLevel.dylib 到底能不能被 arm64e 的
# mediaserverd dlopen 并且安全地跑钩子？逐项检查而不是"看起来编译成功了"。
set -uo pipefail

DIR="${1:-./out}"
F="$DIR/AxsLevel.dylib"
LV="$DIR/axs_lv"
FAIL=0

ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAIL=1; }
say() { echo; echo "== $* =="; }

[ -f "$F" ] || { echo "✗ 没有 $F"; exit 1; }

say "1. 架构"
lipo -info "$F" || bad "lipo 读不出来"
if lipo -info "$F" | grep -q arm64e; then
  ok "含 arm64e slice（关键）"
else
  bad "缺 arm64e slice —— mediaserverd 会拒绝 dlopen（incompatible architecture）"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check_slice () {
  local arch="$1"
  local thin="$TMP/$arch"
  lipo -thin "$arch" -output "$thin" "$F" 2>/dev/null || return

  say "2.$arch. Mach-O 头"
  local hdr cpusub caps
  hdr=$(otool -hv "$thin" | tail -1)
  cpusub=$(echo "$hdr" | awk '{print $3}')
  caps=$(echo "$hdr"    | awk '{print $4}')
  echo "     cputype=$(echo "$hdr" | awk '{print $2}') cpusubtype=$cpusub caps=$caps"

  if [ "$arch" = "arm64e" ]; then
    if [ "$cpusub" = "2" ] && [ "$caps" = "0x80" ]; then
      ok "cpusubtype=2 + caps=0x80 → ABI v2（指针认证版），dlopen 可接受"
    elif [ "$cpusub" = "2" ]; then
      bad "是 arm64e 但 caps=$caps ≠ 0x80 → 没有 ABI v2 标记，ptrauth 缺失"
      bad "  这基本就是 Linux 工具链的产物；改用 Xcode 的 Apple clang"
    else
      bad "cpusubtype=$cpusub，不是 arm64e"
    fi

    say "3.$arch. 指针认证指令"
    local pac
    pac=$(otool -tv "$thin" 2>/dev/null | grep -cE '\b(pacibsp|paciasp|pacia|paciza|autia|retab|autibsp)\b')
    if [ "${pac:-0}" -gt 0 ]; then
      ok "反汇编里找到 $pac 条 ptrauth 指令（函数序言/指针签名真的生成了）"
    else
      bad "一条 ptrauth 指令都没有 —— 这就是「编出来了但一调钩子就打死进程」的根源"
    fi
  fi

  say "4.$arch. 平台与最低版本"
  local plat
  plat=$(otool -l "$thin" | grep -A4 'LC_BUILD_VERSION' | awk '/platform/{print $2; exit}')
  if [ "${plat:-}" = "2" ]; then ok "LC_BUILD_VERSION platform=2 (iOS)"
  else bad "platform=${plat:-无}（2 才是 iOS）"; fi

  say "5.$arch. install_name / 导出符号"
  otool -l "$thin" | grep -A3 'LC_ID_DYLIB' | sed -n 's/.*name \(.*\) (offset.*/     name \1/p'
  local syms
  syms=$(nm -gU "$thin" 2>/dev/null | grep -cE ' _axs_(start|stop|status|version|frames|calls)$')
  if [ "$syms" -ge 6 ]; then ok "C 导出符号齐全（axs_start/stop/status/version/frames/calls）"
  else bad "只找到 $syms 个 axs_* 符号（应为 6）——Lua 侧会取到 nil"; fi
}

if lipo -info "$F" | grep -q arm64e; then check_slice arm64e; fi
if lipo -info "$F" | grep -q 'arm64 ';  then check_slice arm64; fi

say "6. 签名与权限"
if command -v ldid >/dev/null; then
  ENT=$(ldid -e "$F" 2>/dev/null || true)
  if echo "$ENT" | grep -q 'platform-application'; then
    ok "entitlements 含 platform-application"
  else
    bad "entitlements 缺 platform-application —— dlopen 会被拦"
  fi
else
  echo "  (没装 ldid，跳过)"
fi
if command -v codesign >/dev/null; then
  codesign -dv "$F" 2>&1 | grep -E 'Signature|Identifier' | sed 's/^/     /' || true
fi

say "7. axs_lv"
if [ -f "$LV" ]; then
  lipo -info "$LV" | sed 's/^/     /'
  if lipo -info "$LV" | grep -q arm64e; then ok "axs_lv 含 arm64e"; else bad "axs_lv 缺 arm64e"; fi
else
  echo "  (没有 axs_lv)"
fi

say "8. 指纹"
shasum -a 256 "$F" | sed 's/^/     /'
[ -f "$LV" ] && shasum -a 256 "$LV" | sed 's/^/     /'
echo "     （拷到设备后用同一个 shasum 核对，能排除「cp 到了旧文件」这类问题）"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过。可以装机："
  echo "  mkdir -p /var/jb/Library/AxsEQ"
  echo "  cp out/AxsLevel.dylib out/axs_lv /var/jb/Library/AxsEQ/ 2>/dev/null"
  echo "  cp axs_load.lua /var/jb/Library/AxsEQ/"
  echo "  cp out/axs_lv /var/jb/usr/bin/ && chmod +x /var/jb/usr/bin/axs_lv"
  echo "  eqe core"
  echo '  core# dofile("/var/jb/Library/AxsEQ/axs_load.lua")'
else
  echo "有检查项未通过，先别装机。"
  exit 1
fi
