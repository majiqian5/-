#!/bin/bash
# 打 deb（产物可直接 dpkg -i 安装）
# 前提：先跑过 ./build_xcode.sh 且 ./verify.sh 全绿
set -e
V=${1:-1.0}
STAGE=./_pkg

for f in out/AxsLevel.dylib out/axs_lv axs_load.lua; do
  [ -f "$f" ] || { echo "✗ 缺 $f —— 先跑 ./build_xcode.sh"; exit 1; }
done

# 装包前再确认一次架构，避免把无 PAC 的产物打进去
if command -v lipo >/dev/null; then
  lipo -info out/AxsLevel.dylib | grep -q arm64e || {
    echo "✗ out/AxsLevel.dylib 不含 arm64e，拒绝打包"; exit 1; }
fi

rm -rf "$STAGE" && mkdir -p "$STAGE/DEBIAN" \
  "$STAGE/var/jb/Library/AxsEQ" "$STAGE/var/jb/usr/bin"

cp out/AxsLevel.dylib axs_load.lua "$STAGE/var/jb/Library/AxsEQ/"
cp out/axs_lv "$STAGE/var/jb/usr/bin/"
chmod +x "$STAGE/var/jb/usr/bin/axs_lv"

cat > "$STAGE/DEBIAN/control" <<CTL
Package: com.axs.eqlevel
Name: AxsEQ 真实电平载荷
Version: $V
Architecture: iphoneos-arm64
Description: mediaserverd 内真实 PCM 电平（Lua 控制台手动加载，重启失效）
Maintainer: AxsEQ
CTL

cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
echo "装好了。注意 dlopen 按路径缓存："
echo "  如果之前加载过旧版 dylib，必须先 respring / 重启 mediaserverd，"
echo "  否则 ffi.load 拿到的还是旧镜像（axs_load.lua 会报版本不匹配）。"
echo "用法："
echo "  eqe core"
echo '  core# dofile("/var/jb/Library/AxsEQ/axs_load.lua")'
exit 0
POST
chmod +x "$STAGE/DEBIAN/postinst"

dpkg-deb --root-owner-group -b "$STAGE" "AxsEQ_真实电平_$V.deb"
echo "产物：AxsEQ_真实电平_$V.deb"
