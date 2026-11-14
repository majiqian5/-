# AxsEQ 真实电平 — v2 改动说明

原始包：`AxsEQ_真实电平_源码_1114.tar.gz`（v1）
本目录：v2，可直接替换原 `axs_src/`。

---

## 0. 先确认你的前提

> 必须用 macOS + Xcode 的 Apple clang 编。

这条**成立**，而且不是"建议"，是硬约束。原因链是完整的：

| 环节 | 事实 |
|---|---|
| mediaserverd | arm64e 进程 |
| dlopen 校验 | 只接受 `cpusubtype == 2 && caps == 0x80`（arm64e ABI v2） |
| ABI v2 的含义 | 函数指针/返回地址/虚表指针全部走 PAC 签名与校验 |
| Linux clang / Theos | 能出 `-target arm64e`，但**不生成 ptrauth 指令**，产物只有 `cpusubtype 2` 没有 `caps 0x80` |
| 手改 Mach-O 头 | 能骗过 dlopen，但代码里第一条 `pacia`/`autia` 不存在 → 一旦执行到持有签名指针的路径（`MSHookFunction` 内部、`pthread_create` 的 trampoline）就 `EXC_BAD_ACCESS` → 进程被 kill |
| 上游 LLVM | arm64e 的 `-fptrauth-*` 支持不全，实测报 `unknown argument` |
| 结论 | 唯一能产出正确 ABI v2 代码的是 Apple clang |

所以 `build_xcode.sh` 里我加了硬检查：不是 Apple clang 就直接退出，不给你留"也许能行"的空间。

---

## 1. 但编译链不是唯一原因

这是要跟你说清楚的一点：**即使编对了，v1 源码本身还有 4 个独立的致命缺陷**。它们会在"编译完全正确"的情况下照样打死 mediaserverd，或者让电平失真。这也是为什么容易误判成"还是编译的问题"。

### 1.1 重复 hook → 自递归 → 栈爆（最致命）

v1 的 `axs_stop()` 只把 `gHookOK` 清 0，**从不 unhook**：

```c
int axs_stop(void) { gHookOK = 0; return 0; }
```

而 `axs_start()` 只检查 `if (gHookOK) return 0;`。于是：

```
dofile(axs_load.lua)   → MSHookFunction(AudioUnitRender, hookedRender, &gOrigRender)
axs_stop()             → gHookOK = 0（钩子还在）
dofile(axs_load.lua)   → gHookOK==0 → 再调 MSHookFunction 钩"已经是 hookedRender"的地址
                       → gOrigRender 变成指向 hookedRender 自己
                       → hookedRender 调 gOrigRender = hookedRender → 无限递归
                       → 栈溢出 → mediaserverd 被 kill
```

而且 `ffi.load()` 对**同一路径**会返回同一个 handle，所以"改完代码再 dofile 一次"这个最自然的动作，正好踩中这个雷。

**v2 修复**：`gState` 三态 + `atomic_compare_exchange_strong` 抢装钩权。重复调用返回 `0`（已在跑）或 `-20`（并发），永远不会二次 `MSHookFunction`。

### 1.2 realtime 线程里跑重活 + 抢锁

v1 的 `hookedRender` 直接调 `feed()`：10 段 biquad × 最多 1024 帧 = 约 1 万次 double 乘加，**外加** `pthread_mutex_lock`。这跑在 CoreAudio 的 realtime 渲染线程里。

后果不是"慢"，是**错过渲染 deadline**：音频断续、爆音，严重时看门狗直接把 mediaserverd 杀掉。而且 `feed()` 里还有：

```c
static float tmp[1024];   // 函数内 static —— 多线程共享
```

中断/并发渲染时后一次会覆盖前一次的数据。

**v2 修复**：
- 钩子里只做「单声道混音 → 写进 SPSC ring buffer」，无锁、无分配、无 biquad
- 10 段 biquad 全部搬到服务线程，每 33ms 消费一次
- `tmp` 改成栈上 `float scratch[AXS_CHUNK]`

### 1.3 采样率没取、格式当 float 硬读

v1 注释写着"优先问 AudioUnit"，代码却是：

```c
gSampleRate = 44100.0;
bands_init(gSampleRate);
```

而且 `feed()` 里有个反掉的条件：

```c
if (gSampleRate < 8000) bands_init(gSampleRate);   // 采样率正常时反而永不重建
```

更严重的是数据格式：v1 无条件 `(float *)b->mData`。如果这个 AU 输出的是 Int16 或定点格式（`mFormatFlags` 不含 `kAudioFormatFlagIsFloat`），**Int16 的 -32768~32767 会被当成 IEEE754 float 解释**，得到 1e-40 或 1e38 这种值 → `log10` 出 NaN/Inf → 电平条彻底糊死，而进程不崩，所以现象是"挂上了但没数"。

**v2 修复**：
- 按 AU 缓存真实 `AudioStreamBasicDescription`（`AudioUnitGetProperty`，8 槽，命中后不再查询）
- 真的用 `asbd.mSampleRate`
- 非 Float32 走 Int16 路径并按 `1/32768` 换算
- 字节数边界按实际位宽算（v1 写死 `sizeof(float)`）

### 1.4 丢帧不重置滤波器状态 → 假尖峰

v1 的 `if (n > 1024) n = 1024;` 只是截断，被丢掉的样本造成 biquad 状态不连续，输出会出现瞬态尖峰。看起来像"电平偶尔抽一下"。

**v2 修复**：ring buffer 满时置 `gDropped` 位，服务线程消费时检测到就 `bands_reset()`，并把这个状态暴露在 `status` 的 bit3 上，你能直接看到"有没有丢帧"。

---

## 2. 另一个会让你怀疑人生的陷阱：dlopen 镜像缓存

你把新编的 `AxsLevel.dylib` cp 到 `/var/jb/Library/AxsEQ/`，然后 `dofile` —— **dlopen 按路径缓存，mediaserverd 不会重新读文件**。拿到的还是旧镜像，`axs_start` 是旧函数，你看到的现象一模一样。

这跟编译链无关，是排查时最容易走错的一环（"我明明重编了"）。

**v2 修复**：
- 导出 `axs_version()` → `"axs-eq-2.0"`
- `axs_load.lua` 加载后**先比对版本**，不匹配直接报：

```
实际加载了 /var/jb/Library/AxsEQ/AxsLevel.dylib | 版本 = axs-eq-1.0，期望 axs-eq-2.0 |
★ mediaserverd 仍持有旧镜像（dlopen 按路径缓存），新编的 dylib 没生效
```

- 应急手法：换个文件名（`AxsLevel_2.dylib` + 改 Lua 里的路径），不用重启进程也能加载新代码

---

## 3. 面板侧（AxsTcpLevels.m）的冻结 bug

v1 这里：

```c
if (r > 0) { ...; continue; }
if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
if (r < 0) { close(s_fd); s_fd = -1; return NO; }
break;    // r == 0：对端关闭 —— 只 break，不 close
```

`r == 0` 时只 `break`，`s_fd` 保持有效但永远是 EOF。下一次 `recv` 还是立刻返回 0，继续 `break`，`parseLatest` 拿不到新数据 → **面板电平永久冻结在最后一帧，而且永不重连**。每次 mediaserverd 重启、每次 `axs_stop`，你的面板就死一次，只能重启 App。

**v2 修复**：
- `r == 0` → `close` + 置 `-1`，下一帧自动重连
- 连接失败退避 500ms（v1 在 30Hz 刷新下每秒 30 次 `socket()+connect()`）
- `parseLatest` 重写：取最后一个完整行，只保留残余半行；v1 解析失败时 `strcpy(s_acc, "")` 会连刚收到的后续数据一起清掉
- 新增 `AxsTcpResetLevels()`，离开面板页时主动断开

---

## 4. 文件对照

| 文件 | 状态 | 说明 |
|---|---|---|
| `AxsLevel.m` | 重写 | 4 个致命缺陷全部修复，新增 `axs_version()` |
| `AxsTcpLevels.m` | 重写 | 断线重连、退避、parseLatest |
| `axs_load.lua` | 重写 | 版本校验、cdef 容错、cdata 数值转换 |
| `axs_lv.c` | 重写 | 加 2s 接收超时（v1 会永久 hang）、按行输出、退出码分级 |
| `build_xcode.sh` | 重写 | 硬检查 Apple clang / 完整 Xcode / ldid；arm64e+arm64 双 slice；编完自动 verify |
| `verify.sh` | 新增 | 逐项自证 cpusubtype/caps/ptrauth 指令/platform/符号/entitlements |
| `Makefile` | 保留 | 只作语法参考，**Linux 产物不可用**（原注释已说明） |
| `ent.plist` | 未改 | 够用 |
| `make_deb.sh` | 微调 | 适配 out/ 新结构 |

---

## 5. Mac 上的执行流程

```sh
cd axs_src

# 0) 确认工具链（不通过就别往下走）
xcode-select -p                       # 必须是 /Applications/Xcode.app/...
xcodebuild -version                   # Xcode 14 以上
brew install ldid-procursus           # 没有 ldid 就直接退出，不给你 codesign 兜底

# 1) 编译 + 自证（一条命令，失败会告诉你哪一项不过）
./build_xcode.sh

# 2) 装机
mkdir -p /var/jb/Library/AxsEQ
cp out/AxsLevel.dylib axs_load.lua /var/jb/Library/AxsEQ/
cp out/axs_lv /var/jb/usr/bin/ && chmod +x /var/jb/usr/bin/axs_lv

# 3) 加载
eqe core
#   core# dofile("/var/jb/Library/AxsEQ/axs_load.lua")
```

### `verify.sh` 该看到的输出

```
1. 架构
  ✓ 含 arm64e slice（关键）
2.arm64e. Mach-O 头
     cputype=16777228 cpusubtype=2 caps=0x80
  ✓ cpusubtype=2 + caps=0x80 → ABI v2（指针认证版），dlopen 可接受
3.arm64e. 指针认证指令
  ✓ 反汇编里找到 N 条 ptrauth 指令（函数序言/指针签名真的生成了）
4.arm64e. 平台与最低版本
  ✓ LC_BUILD_VERSION platform=2 (iOS)
5.arm64e. install_name / 导出符号
  ✓ C 导出符号齐全（axs_start/stop/status/version/frames/calls）
6. 签名与权限
  ✓ entitlements 含 platform-application
```

**任何一项 ✗ 都别装机**。特别是第 2、3 项 —— 那就是"编出来了但一跑就死"的分界线。

---

## 6. 系统设计上，本就没有取 PCM 的公开 API

v1 的 README 已经踩明了：厂商 dylib 的 Lua 侧只暴露 `FILTER_*`，没有取 PCM 的接口；`vm_protect` 在系统库代码页上返回 `kr=1`，写不了自研 inline hook；`ffi.callback` 不支持。所以"钩 `AudioUnitRender`"是当前半越狱条件下唯一能拿到真实 PCM 的路径，这个方向是对的。

v2 没有改这个方向，只是把这条路径上的工程缺陷清掉，并把它从"可能崩"变成"可观测"：`axs_status()` 四个位 + `axs_version()` + `verify.sh`，出问题能定位到具体一层（工具链/加载/钩子/格式/端口/文件）。

---

## 7. 电平标定

v2 用的是 RBJ 恒定 0 dB 峰值增益带通，语义是：**中心频率处的满刻度正弦 → 读数 100**。也就是 dBFS 严格对应。

标定步骤（想验证映射对不对）：

1. 播 1 kHz 满刻度正弦（`0 dBFS`）→ `1000` 那一段应该接近 90~100
2. 播 -20 dBFS 的 1 kHz → 同一段应接近 66~67（`(20*log10(0.1)+60)/60*100 = 66.67`）
3. 播白噪 → 各段读数不相等是正常的（窄带滤波器只取该频带能量），低频段会偏低

如果觉得音乐观感太"平"，改 `AxsLevel.m` 里的：

```c
static const double gBandCompDb[AXS_BANDS] = {0,0,0,0,0,0,0,0,0,0};
```

按段给 +3 ~ +6 dB（`gBandComp` 用之前会自动线性化）。**别拍脑袋给很大值**，会一直顶在 100。

---

## 8. 症状 → 原因 → 动作

| 症状 | 原因 | 动作 |
|---|---|---|
| `dylib 加载失败`，err 里是 `incompatible architecture` | 产物不是 arm64e ABI v2 | 跑 `verify.sh` 看第 2、3 项 |
| 加载成功，但 `calls=0` 一直不涨 | 钩子装上了但没匹配到 AU / 只放了个静音 | 真放歌；看 `status` bit0 |
| 一 `dofile` 就 respring / 音频断 | 又是旧 dylib 的双重 hook（v1 的坑），或产物无 ptrauth | 看版本号；`verify.sh` 第 3 项 |
| `status=bit0` 但电平全是 0 | 格式判断走错（Int16 被当 float 的历史问题） | v2 已修；确认没在跑 v1 |
| 面板电平冻结不动 | v1 的 `r==0` 不重连 | 用 v2 的 `AxsTcpLevels.m` |
| `axs_lv` 打出 `connect 失败` | 载荷没起 / 端口没 bind | 先看 `status` bit1 |
| 改完代码行为没变 | dlopen 镜像缓存 | 换文件名，或重启 mediaserverd |
