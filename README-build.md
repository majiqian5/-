# 用 GitHub / macOS 编译 IslandHLS

这套目录是为「在 macOS 上用 Xcode 的 clang 编 arm64e PAC ABI v2」准备的。
Linux 的 clang 11 编不出带 PAC 的 arm64e 切片，只能手工改 Mach-O 头凑过去；macOS 上则是原生的。

## 一、推到 GitHub，让 Actions 编

1. 在 GitHub 新建一个空仓库（Private 也行）
2. 把本目录全部文件传上去（含 `.github/workflows/build.yml`）
3. 进仓库 → Actions → 选 `build` → Run workflow（或直接 push 触发）
4. 跑完在 run 页面底部下载 artifact `IslandHLS-deb`，里面就是 `com.you.islandhls_0.2.1_iphoneos-arm64.deb`

装法：
```bash
dpkg -i com.you.islandhls_0.2.1_iphoneos-arm64.deb
killall -9 SpringBoard
```

## 二、本机 macOS 直接编

```bash
brew install ldid xz
git clone --recursive https://github.com/theos/theos.git ~/theos
curl -sL https://github.com/theos/sdks/archive/refs/heads/master.zip -o sdks.zip
unzip -q sdks.zip && mkdir -p ~/theos/sdks && cp -r sdks-master/*.sdk ~/theos/sdks/

export THEOS=~/theos
make clean
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

## 三、怎么确认编出来的确实是 PAC ABI v2

```bash
file .theos/obj/arm64e/IslandHLS.dylib
# 期望：Mach-O 64-bit arm64e (caps: PAC00) ...

python3 -c "import struct;print(hex(struct.unpack('<I',open('.theos/obj/arm64e/IslandHLS.dylib','rb').read()[8:12])[0]))"
# 期望：0x80000002
```

如果还是 `0x2`，说明 Xcode 命令行工具版本太老，`xcode-select -s /Applications/Xcode.app` 切到完整 Xcode 再编。

## 四、目录说明

```
Tweak.xm                         播放逻辑（可直接改源码里的 kDefaultURL）
Makefile                         ARCHS = arm64 arm64e，rootless
control                          deb 元信息
IslandHLS.plist                  过滤器：Bundles + Executables（macOS 上 Theos 会自动转 binary）
.github/workflows/build.yml      GitHub Actions：macos-13 + Theos 全自动编译
```
