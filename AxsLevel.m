//
//  AxsLevel.m — mediaserverd 内真实音频电平载荷（v2）
//  编译：arm64e（必须 Apple clang；Linux 工具链无 PAC，dlopen 后一调钩子就打穿 mediaserverd）
//  作者：AxsEQ
//
//  v2 相对 v1 的硬改动（每一条都对应一次实际崩溃/失真/不生效）：
//   1. hook 状态机 + CAS：重复 dofile / 重复 ffi.load 不会二次 MSHookFunction。
//      （v1 的 axs_stop 只清标志、从不 unhook，再 start 时把已钩过的地址再钩一层，
//        原函数指针指向自己的钩子 → 自递归 → 栈爆 → mediaserverd 直接被 kill。）
//   2. realtime 线程只做「单声道混音 + 拷进 ring buffer」，10 段 biquad 全部搬到
//      服务线程。v1 在音频回调里跑 10×1024 次 double biquad 并抢 mutex，
//      渲染窗口偶尔超时 → 音频断续甚至 watchdog 杀进程。
//   3. 采样率与样本格式从 AudioUnit 真实 ASBD 取（按 AU 缓存），非 Float32
//      (Int16/定点) 按比例换算。v1 硬编 44100 且把任意格式都当 float 读，
//      Int16 数据被当 float 解释 → 数值巨大/NaN → 电平条直接糊死。
//   4. 丢样本时清 biquad 状态。ring buffer 溢出丢帧会造成滤波器状态跳变，
//      不清的话会出现瞬间尖峰（看起来像"爆音"）。
//   5. axs_version()：dlopen 对同路径 dylib 有镜像缓存，改了代码不重启进程
//      拿到的还是旧镜像。Lua 侧必须先比对版本，否则你会以为"编了没用"。
//   6. 监听/目录失败都有明确返回码，不再静默 status=0。
//
//  由厂商 EQE 的 Lua 控制台加载（`eqe core` → dofile axs_load.lua），不靠越狱注入。
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>

#define AXS_BANDS        10
#define AXS_PORT         47923
#define AXS_TMP          "/var/tmp/AxsEQ"
#define AXS_LEVELS       AXS_TMP "/levels.txt"
#define AXS_VERSION      "axs-eq-2.0"

#define AXS_RB_FRAMES    32768              // 2^15，约 0.74s @44.1k
#define AXS_RB_MASK      (AXS_RB_FRAMES - 1)
#define AXS_CHUNK        1024               // 单个 IOProc 最多处理的帧数
#define AXS_PULL         8192               // 服务线程每次最多消费的帧数
#define AXS_FMT_SLOTS    8                  // AU → ASBD 缓存槽位

// ---------------------------------------------------------------- 返回码
//  1  成功
//  0  已经在跑（幂等）
// -10 找不到 MSHookFunction
// -11 找不到 AudioUnitRender
// -12 MSHookFunction 没回填原函数指针
// -20 并发 start（另一个线程正在装钩子）
// -30 socket / bind / listen 失败（钩子本身仍然装上了）
#define AXS_OK           1
#define AXS_ALREADY      0
#define AXS_E_NOHOOK    (-10)
#define AXS_E_NOSYM     (-11)
#define AXS_E_NOORIG    (-12)
#define AXS_E_BUSY      (-20)

// ---------------------------------------------------------------- 状态
static _Atomic int  gHookOK  = 0;           // 1 = 钩子已装
static _Atomic int  gSrvOK   = 0;           // 1 = 端口在听
static _Atomic int  gWriteOK = 0;           // 1 = 能写兜底文件
static _Atomic int  gDropped = 0;           // 1 = 曾经丢过样本（诊断位）
static _Atomic int  gRun     = 0;           // 1 = 分析线程继续工作

// start 幂等状态：0=空闲 1=正在装 2=已装 3=装失败
static _Atomic int  gState = 0;

static _Atomic long gCalls  = 0;
static _Atomic long gFrames = 0;

static double gBand[AXS_BANDS];             // 0..100，最近一次电平
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

// 导出给 Lua 查询
__attribute__((visibility("default"))) const char *axs_version(void) { return AXS_VERSION; }
__attribute__((visibility("default"))) int  axs_status(void) {
    return (atomic_load(&gHookOK)  << 0)
         | (atomic_load(&gSrvOK)   << 1)
         | (atomic_load(&gWriteOK) << 2)
         | (atomic_load(&gDropped) << 3);
}
__attribute__((visibility("default"))) long axs_frames(void) { return atomic_load(&gFrames); }
__attribute__((visibility("default"))) long axs_calls(void)  { return atomic_load(&gCalls);  }

// ---------------------------------------------------------------- ring buffer（SPSC）
static float    gRB[AXS_RB_FRAMES];
static _Atomic uint32_t gRBW = 0;
static _Atomic uint32_t gRBR = 0;

static inline void rb_push(const float *src, int n) {
    uint32_t w = atomic_load_explicit(&gRBW, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&gRBR, memory_order_acquire);
    uint32_t space = AXS_RB_FRAMES - (w - r);
    if (space == 0) { atomic_store(&gDropped, 1); return; }
    if ((uint32_t)n > space) { n = (int)space; atomic_store(&gDropped, 1); }
    for (int i = 0; i < n; i++) gRB[(w + i) & AXS_RB_MASK] = src[i];
    atomic_store_explicit(&gRBW, w + (uint32_t)n, memory_order_release);
}

static inline int rb_pop(float *dst, int max) {
    uint32_t r = atomic_load_explicit(&gRBR, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&gRBW, memory_order_acquire);
    uint32_t avail = w - r;                       // 32 位回绕也成立
    if ((uint32_t)max > avail) max = (int)avail;
    for (int i = 0; i < max; i++) dst[i] = gRB[(r + i) & AXS_RB_MASK];
    atomic_store_explicit(&gRBR, r + (uint32_t)max, memory_order_release);
    return max;
}

// ---------------------------------------------------------------- 10 段 biquad
typedef struct { double b0,b1,b2,a1,a2; double x1,x2,y1,y2; } Biquad;
static Biquad gF[AXS_BANDS];

// 每段可调补偿（dB）。默认为 0 = RBJ 恒定 0dB 峰值增益，正弦满刻度在中心频率读数 0dBFS。
// 想让音乐观感更饱满可给低频段 +3~+6；标定方法见 README「标定」一节。
static const double gBandCompDb[AXS_BANDS] = {0,0,0,0,0,0,0,0,0,0};
static double gBandComp[AXS_BANDS];           // 线性化后的补偿
static double gCalibSr = 0.0;                 // 当前系数对应的采样率

// RBJ 带通（恒定 0dB 峰值增益），f0 中心频率，Q 可调
static void bq_bandpass(Biquad *q, double f0, double Q, double sr) {
    double w0 = 2.0 * M_PI * f0 / sr;
    double alpha = sin(w0) / (2.0 * Q);
    double a0 = 1.0 + alpha;
    q->b0 =  alpha / a0;
    q->b1 =  0.0;
    q->b2 = -alpha / a0;
    q->a1 = (-2.0 * cos(w0)) / a0;
    q->a2 = (1.0 - alpha) / a0;
    q->x1 = q->x2 = q->y1 = q->y2 = 0.0;
}

static void bands_reset(void) {
    for (int i = 0; i < AXS_BANDS; i++) gF[i].x1 = gF[i].x2 = gF[i].y1 = gF[i].y2 = 0.0;
}

static void bands_init(double sr) {
    static const double centers[AXS_BANDS] = {31,62,125,250,500,1000,2000,4000,8000,16000};
    if (sr < 8000.0) sr = 44100.0;                       // 非法采样率兜底
    if (gCalibSr == sr) return;                          // 同采样率不重建（保留滤波器状态）
    for (int i = 0; i < AXS_BANDS; i++) {
        double f0 = centers[i];
        if (f0 > sr * 0.45) f0 = sr * 0.45;              // 低采样率时搬移越界中心频率
        bq_bandpass(&gF[i], f0, 1.2, sr);
        gBandComp[i] = pow(10.0, gBandCompDb[i] / 20.0);
    }
    gCalibSr = sr;
}

static inline double bq_run(Biquad *q, double x) {
    double y = q->b0*x + q->b1*q->x1 + q->b2*q->x2 - q->a1*q->y1 - q->a2*q->y2;
    q->x2 = q->x1; q->x1 = x;
    q->y2 = q->y1; q->y1 = y;
    return y;
}

// 只允许服务线程调用：biquad 状态不再被多个线程共享
static void feed(const float *p, int n) {
    if (n <= 0) return;
    double acc[AXS_BANDS];
    for (int i = 0; i < AXS_BANDS; i++) acc[i] = 0.0;
    for (int k = 0; k < n; k++) {
        double x = (double)p[k];
        for (int i = 0; i < AXS_BANDS; i++) {
            double y = bq_run(&gF[i], x);
            acc[i] += y * y;
        }
    }
    pthread_mutex_lock(&gLock);
    for (int i = 0; i < AXS_BANDS; i++) {
        double e  = sqrt(acc[i] / (double)n) * gBandComp[i];   // 段 RMS
        double db = 20.0 * log10(e + 1e-9);                    // dBFS
        double v  = (db + 60.0) / 60.0 * 100.0;                // -60..0 dB → 0..100
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        // 上升快、下降慢
        gBand[i] = (v > gBand[i]) ? (gBand[i]*0.3 + v*0.7) : (gBand[i]*0.85 + v*0.15);
    }
    pthread_mutex_unlock(&gLock);
}

// ---------------------------------------------------------------- 钩子
typedef OSStatus (*RenderFn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                             UInt32, UInt32, AudioBufferList *);
typedef void (*HookFn)(void *, void *, void **);

static RenderFn gOrigRender = NULL;

// AU → (采样率, 是否 Float32) 缓存。AudioUnitGetProperty 可能在内部加锁，
// 不能每帧都调；命中后就再也不查。
typedef struct {
    AudioUnit     au;
    double        sr;
    int           isFloat;
    _Atomic int   valid;
} FmtSlot;
static FmtSlot gFmt[AXS_FMT_SLOTS];
static _Atomic int gFmtNext = 0;
static double gLastSr = 44100.0;

static void fmt_probe(AudioUnit au) {
    AudioStreamBasicDescription asbd; memset(&asbd, 0, sizeof asbd);
    UInt32 sz = (UInt32)sizeof asbd;
    OSStatus st = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0, &asbd, &sz);
    if (st != noErr || asbd.mSampleRate <= 0.0) {
        sz = (UInt32)sizeof asbd;
        st = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0, &asbd, &sz);
    }
    double sr = (st == noErr && asbd.mSampleRate > 0.0) ? asbd.mSampleRate : gLastSr;
    int isFloat = 1;
    if (st == noErr) {
        if ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) &&
            (asbd.mBitsPerChannel == 32 || asbd.mBitsPerChannel == 64)) {
            isFloat = 1;
        } else {
            isFloat = 0;                       // Int16 / 定点 / 其它：按 16bit 解释
        }
    }
    int slot = atomic_fetch_add(&gFmtNext, 1) & (AXS_FMT_SLOTS - 1);
    gFmt[slot].au      = au;
    gFmt[slot].sr      = sr;
    gFmt[slot].isFloat = isFloat;
    atomic_store(&gFmt[slot].valid, 1);
    gLastSr = sr;
    bands_init(sr);
}

static inline const FmtSlot *fmt_lookup(AudioUnit au) {
    for (int i = 0; i < AXS_FMT_SLOTS; i++) {
        if (atomic_load(&gFmt[i].valid) && gFmt[i].au == au) return &gFmt[i];
    }
    fmt_probe(au);
    for (int i = 0; i < AXS_FMT_SLOTS; i++) {
        if (atomic_load(&gFmt[i].valid) && gFmt[i].au == au) return &gFmt[i];
    }
    return NULL;
}

static OSStatus hookedRender(AudioUnit au, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts,
                             UInt32 bus, UInt32 frames, AudioBufferList *io) {
    if (!gOrigRender) return paramErr;

    OSStatus st = gOrigRender(au, fl, ts, bus, frames, io);

    // ---- 以下全部跑在 realtime 线程：只做混音 + 拷贝，绝不加锁、绝不跑 biquad
    if (st != noErr || !io || frames == 0 || !atomic_load(&gRun)) return st;
    if (fl && (*fl & kAudioUnitRenderAction_OutputIsSilence)) return st;  // 静音帧不分析
    if (io->mNumberBuffers == 0) return st;
    if (!io->mBuffers[0].mData) return st;

    const FmtSlot *f = fmt_lookup(au);
    double sr = f ? f->sr : gLastSr;
    int isFloat = f ? f->isFloat : 1;

    int n = (frames > AXS_CHUNK) ? AXS_CHUNK : (int)frames;
    AudioBuffer *b = &io->mBuffers[0];
    int ch = (int)b->mNumberChannels;
    if (ch <= 0) ch = 1;

    // 非交错（每 buffer 1 通道）时 stride 恒为 1；交错时按通道数跨步
    int stride = ch;

    // 字节数边界：按实际位宽算，不能写死 sizeof(float)
    UInt32 bytesPerSample = isFloat ? 4u : 2u;
    UInt32 need = (UInt32)n * (UInt32)stride * bytesPerSample;
    if (b->mDataByteSize < need) return st;

    float scratch[AXS_CHUNK];                  // 栈上，避免 v1 的 static 竞态
    if (isFloat) {
        const float *src = (const float *)b->mData;
        if (stride == 1) {
            for (int i = 0; i < n; i++) scratch[i] = src[i];
        } else if (stride == 2) {
            for (int i = 0; i < n; i++) scratch[i] = (src[i*2] + src[i*2+1]) * 0.5f;
        } else {
            for (int i = 0; i < n; i++) scratch[i] = src[i*stride];   // 取第一通道
        }
    } else {
        const int16_t *src = (const int16_t *)b->mData;
        const float k = 1.0f / 32768.0f;
        if (stride == 1) {
            for (int i = 0; i < n; i++) scratch[i] = (float)src[i] * k;
        } else if (stride == 2) {
            for (int i = 0; i < n; i++) scratch[i] = (float)(src[i*2] + src[i*2+1]) * 0.5f * k;
        } else {
            for (int i = 0; i < n; i++) scratch[i] = (float)src[i*stride] * k;
        }
    }

    atomic_fetch_add(&gCalls, 1);
    atomic_fetch_add(&gFrames, (long)n);
    rb_push(scratch, n);
    (void)sr;

    return st;
}

// ---------------------------------------------------------------- TCP 服务 + 分析线程
static int gListenFD = -1;

// 把电平量成一行 "AXS xx.xx ...\n"，返回长度
static int format_levels(char *line, size_t cap) {
    pthread_mutex_lock(&gLock);
    int n = snprintf(line, cap,
                     "AXS %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f\n",
                     gBand[0],gBand[1],gBand[2],gBand[3],gBand[4],
                     gBand[5],gBand[6],gBand[7],gBand[8],gBand[9]);
    pthread_mutex_unlock(&gLock);
    return n;
}

static int srv_listen(void) {
    if (gListenFD >= 0) return 1;
    mkdir(AXS_TMP, 0777);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in ad; memset(&ad, 0, sizeof ad);
    ad.sin_family = AF_INET;
    ad.sin_port   = htons(AXS_PORT);
    ad.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&ad, sizeof ad) < 0) { close(fd); return 0; }
    if (listen(fd, 4) < 0) { close(fd); return 0; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    gListenFD = fd;
    return 1;
}

static void *srv_thread(void *arg) {
    (void)arg;
    int clients[4] = {-1,-1,-1,-1};
    char line[192];
    static float pull[AXS_PULL];

    while (1) {
        // 线程常驻：stop 只是让它空转，避免反复创建/关闭监听带来的 fd 竞态
        if (!atomic_load(&gRun)) { usleep(50000); continue; }

        // 1) 消费 ring buffer 并分析（biquad 只在本线程跑）
        int got;
        while ((got = rb_pop(pull, AXS_PULL)) > 0) {
            if (atomic_exchange(&gDropped, 0)) bands_reset();  // 丢过帧 → 清状态防尖峰
            feed(pull, got);
        }

        // 2) 端口没起来就重试一次（介质服务启动早期沙盒可能还没就绪）
        if (gListenFD < 0 && srv_listen()) atomic_store(&gSrvOK, 1);

        // 3) 接新客户端
        if (gListenFD >= 0) {
            int c;
            while ((c = accept(gListenFD, NULL, NULL)) >= 0) {
                int placed = 0;
                for (int i = 0; i < 4; i++) {
                    if (clients[i] < 0) { clients[i] = c; placed = 1; break; }
                }
                if (!placed) { close(c); }      // 满了就踢掉新的，别泄漏 fd
            }
        }

        // 4) 发一行 + 写兜底文件
        int n = format_levels(line, sizeof line);
        if (n > 0 && n < (int)sizeof line) {
            for (int i = 0; i < 4; i++) {
                if (clients[i] < 0) continue;
                if (send(clients[i], line, (size_t)n, MSG_NOSIGNAL) <= 0) {
                    close(clients[i]); clients[i] = -1;
                }
            }
            FILE *f = fopen(AXS_LEVELS ".tmp", "w");
            if (f) {
                fputs(line, f);
                fclose(f);
                if (rename(AXS_LEVELS ".tmp", AXS_LEVELS) == 0) atomic_store(&gWriteOK, 1);
            }
        }
        usleep(33000);   // ≈30Hz
    }
    return NULL;         // 不会到达
}

// ---------------------------------------------------------------- 安装
static void *resolve(const char *names[], const char *sym) {
    void *p = dlsym(RTLD_DEFAULT, sym);
    if (p) return p;
    for (int i = 0; names[i]; i++) {
        void *h = dlopen(names[i], RTLD_NOW);
        if (h) { void *s = dlsym(h, sym); if (s) return s; }
    }
    return NULL;
}

static _Atomic int gThreadUp = 0;

// 线程常驻，只创建一次
static void ensure_thread(void) {
    int e = 0;
    if (!atomic_compare_exchange_strong(&gThreadUp, &e, 1)) return;
    pthread_t t;
    if (pthread_create(&t, NULL, srv_thread, NULL) == 0) pthread_detach(t);
    else atomic_store(&gThreadUp, 0);       // 失败则下次 start 再试
}

__attribute__((visibility("default"))) int axs_start(void) {
    // ---- 幂等：CAS 拿装钩权，重复调用绝不二次 MSHookFunction
    int expect = 0;
    if (!atomic_compare_exchange_strong(&gState, &expect, 1)) {
        if (expect == 2) {
            // 钩子已装过：只恢复分析线程，不再碰 MSHookFunction
            atomic_store(&gRun, 1);
            atomic_store(&gHookOK, 1);
            ensure_thread();
            if (srv_listen()) atomic_store(&gSrvOK, 1);
            return AXS_ALREADY;
        }
        if (expect == 1) return AXS_E_BUSY;
        return AXS_E_NOSYM;                 // 上次装失败，需要重启 mediaserverd 再试
    }

    int rc;
    static const char *substrates[] = {
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        NULL
    };

    HookFn hook = (HookFn)resolve(substrates, "MSHookFunction");
    if (!hook) { rc = AXS_E_NOHOOK; goto fail; }

    void *au = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    void *sym = au ? dlsym(au, "AudioUnitRender") : NULL;
    if (!sym) sym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (!sym) { rc = AXS_E_NOSYM; goto fail; }

    bands_init(gLastSr);

    hook(sym, (void *)hookedRender, (void **)&gOrigRender);
    if (!gOrigRender) { rc = AXS_E_NOORIG; goto fail; }

    atomic_store(&gRun, 1);
    atomic_store(&gHookOK, 1);
    ensure_thread();

    // 同步建监听，这样第一次 axs_status 的 bit1 就是真的
    if (srv_listen()) atomic_store(&gSrvOK, 1);

    atomic_store(&gState, 2);
    return AXS_OK;

fail:
    atomic_store(&gState, 3);
    return rc;
}

// 停止分析。MSHookFunction 无法安全回滚，钩子保持安装，
// 但 gRun=0 后钩子直接透传原函数、线程空转不发数据，等价于「停」。
// 再调 axs_start 会恢复（不重新装钩，所以不会二次 hook）。
// 想换代码必须换 dylib 路径或重启 mediaserverd（dlopen 按路径缓存）。
__attribute__((visibility("default"))) int axs_stop(void) {
    atomic_store(&gRun, 0);
    atomic_store(&gHookOK, 0);
    return 0;
}
