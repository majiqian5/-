# AxsEQ 真实电平载荷（源码 v2）

在厂商 EQE 的 mediaserverd Lua 控制台里手动加载，钩 `AudioUnitRender` 取真实 PCM，
10 段能量以 30Hz 通过 `127.0.0.1:47923` 送出，同时兜底写 `/var/tmp/AxsEQ/levels.txt`。
不靠越狱注入 → 重启即失效，不会触发安全模式。

> **v2 改动全在 [`CHANGES.md`](CHANGES.md)**：修掉 4 个会打死 mediaserverd 的源码缺陷、
> dlopen 镜像缓存的排查盲区、以及面板侧电平冻结的 bug。先读它再动手。

## 编译（硬约束）

```sh
./build_xcode.sh        # 产物在 ./out/，编完自动 verify.sh
```

必须是 **macOS + 完整 Xcode 的 Apple clang**。mediaserverd 是 arm64e，
dylib 必须是 ABI v2（`cpusubtype 2` + `caps 0x80` + 真实 ptrauth 指令）。
Linux 上的 Theos/clang 能出 `-target arm64e` 但不生成 PAC 代码，
手改 Mach-O 头能骗过 dlopen，一调用 `MSHookFunction` 就打穿进程。
`build_xcode.sh` 会硬检查这一点，不通过直接退出。

## 文件

| 文件 | 说明 |
|---|---|
| `AxsLevel.m` | 载荷本体：钩子 + 10 段 biquad + ring buffer + TCP 服务 + 写文件兜底 |
| `axs_load.lua` | Lua 加载器，含 `axs_version()` 校验 |
| `axs_lv.c` | 设备端命令行自测工具（2s 超时，打印 20 行电平） |
| `AxsTcpLevels.m` | 面板侧消费端，`AxsTcpPollLevels(float out[10])` |
| `build_xcode.sh` | macOS 一键编译 + ldid 签名 + 自动校验 |
| `verify.sh` | 产物自证：架构 / ABI v2 / ptrauth 指令 / platform / 符号 / 权限 |
| `Makefile` | Theos 构建，**仅语法参考，产物不可用** |
| `ent.plist` | 必需权限：`platform-application` 等 |
| `make_deb.sh` | 打 deb（会再验一次 arm64e） |

## 装机

```sh
mkdir -p /var/jb/Library/AxsEQ
cp out/AxsLevel.dylib axs_load.lua /var/jb/Library/AxsEQ/
cp out/axs_lv /var/jb/usr/bin/ && chmod +x /var/jb/usr/bin/axs_lv

eqe core
#  core# dofile("/var/jb/Library/AxsEQ/axs_load.lua")
```

期望返回：

```
loaded /var/jb/Library/AxsEQ/AxsLevel.dylib | start=1  ... |
status=7 [钩子+端口+写文件] | calls=0 frames=0 ...
```

`status` 是位图：bit0 钩子 / bit1 端口 / bit2 写文件 / bit3 曾丢帧。
放几秒歌后再执行一次同名脚本，`calls`/`frames` 应该从 0 变成几千。

如果看到 `版本 = ...，期望 axs-eq-2.0`，说明 mediaserverd 还持有旧镜像
（dlopen 按路径缓存），换文件名或重启进程。

## 自测

```sh
axs_lv              # 连续打印 20 行，形如 AXS 42.10 55.63 ...
axs_lv 60           # 打 60 行
cat /var/tmp/AxsEQ/levels.txt
```

`axs_lv` 退出码：0 正常 / 1 连不上（载荷没起）/ 3 连上但 2s 无数据（钩子在但没分析）/ 4 其它错误。

## 接面板

把 `AxsTcpLevels.m` 加进面板工程，在 `pollLevels` 最前面：

```objc
float lv[10];
if (AxsTcpPollLevels(lv)) { /* 用 lv 画 10 段 */ }
else { /* 保留原来的 fallback */ }
```

离开面板页时调一次 `AxsTcpResetLevels()`。

## 标定

RBJ 恒定 0 dB 峰值增益带通，语义是「中心频率处满刻度正弦 → 读数 100」，即严格 dBFS。

- 1 kHz @ 0 dBFS → 1000 那段 ≈ 100
- 1 kHz @ -20 dBFS → 同一段 ≈ 66.7
- 白噪各段读数不等是正常的（窄带只取该频带能量）

观感太"平"可改 `AxsLevel.m` 的 `gBandCompDb[]`，每段 +3~+6 dB，别给太大。

## 环境事实（这台机器实测，v1 沿用）

- `/var/jb/Library/AxsEQ/`、`/var/tmp/`、`/var/jb/tmp/` 在 mediaserverd 沙盒内**可写**；
  `/var/jb/com.r333d.eqe/`、`/var/mobile/Media/` **不可写**。
- `127.0.0.1:47923` 在 mediaserverd 内 **bind+listen 成功**（沙盒允许回环监听）。
- 厂商 EQE 的 Lua 模块名是 `cffi`（`ffi` 加载失败），**不支持 `ffi.callback`**，
  所以"用 Lua 造回调再挂钩子"这条路不通。
- 系统库代码页在当前半越狱下**不能被改成可写**（`vm_protect` 返回 `kr=1`），写不了自研 inline hook。
- 厂商 dylib 自己钩成功，是因为它是 Xcode 编的正规 arm64e；它的 Lua 侧只暴露
  `FILTER_*` 滤波接口，**没有**取 PCM 的 API。
- `eqe core` 的控制台只回显"表达式返回值"，`print` 会被吞掉，所以加载器里用 `return`。
- 不要在控制台里敲 shell 命令（`tail`/`ls` 会报 `attempt to perform arithmetic on a nil value`），
  要先 `exit` 回 `iPhone#`。
