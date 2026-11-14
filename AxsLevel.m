//
//  AxsLevel.m — mediaserverd 内真实音频电平载荷
//  编译：arm64e（必须用 Xcode 的 Apple clang，Linux 工具链无法生成 PAC 代码）
//  作者：AxsEQ
//
//  工作原理：
//   1. 进程内 dlopen CydiaSubstrate，用 MSHookFunction 钩 AudioUnitRender
//   2. 钩子里对 PCM 做 10 段 biquad 带通，统计每段能量
//   3. 后台线程把电平以 "l0,..,l9" 的浮点行按 30Hz 通过 TCP 127.0.0.1:47923 送出
//   4. 兜底：同时写 /var/tmp/AxsEQ/levels.txt（root 侧守护可再搬到面板容器）
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

#define AXS_BANDS   10
#define AXS_PORT    47923
#define AXS_TMP     "/var/tmp/AxsEQ"
#define AXS_LEVELS  AXS_TMP "/levels.txt"

// ---------------------------------------------------------------- 状态
static volatile int  gHookOK   = 0;      // 1 = 钩子已安装
static volatile long gCalls    = 0;      // AudioUnitRender 被调用次数
static volatile long gFrames   = 0;      // 累计采样帧数
static volatile int  gSrvOK    = 0;      // 端口监听就绪
static volatile int  gWriteOK  = 0;      // 能写文件

static double gBand[AXS_BANDS];          // 最近一次电平（0..100）
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

// 导出给 Lua 查询
__attribute__((visibility("default"))) int  axs_status(void) { return (gHookOK<<0)|(gSrvOK<<1)|(gWriteOK<<2); }
__attribute__((visibility("default"))) long axs_frames(void) { return gFrames; }
__attribute__((visibility("default"))) long axs_calls(void)  { return gCalls;  }

// ---------------------------------------------------------------- 10 段 biquad
typedef struct { double b0,b1,b2,a1,a2; double x1,x2,y1,y2; } Biquad;
static volatile double gInScale = 0.0;   // 0 = 未探测；1.0 = 浮点；1/32768 = int16
static Biquad gF[AXS_BANDS];

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

static void bands_init(double sr) {
    static const double centers[AXS_BANDS] = {31,62,125,250,500,1000,2000,4000,8000,16000};
    for (int i = 0; i < AXS_BANDS; i++)
        bq_bandpass(&gF[i], centers[i], 1.2, sr);
}

static inline double bq_run(Biquad *q, double x) {
    double y = q->b0*x + q->b1*q->x1 + q->b2*q->x2 - q->a1*q->y1 - q->a2*q->y2;
    q->x2 = q->x1; q->x1 = x;
    q->y2 = q->y1; q->y1 = y;
    return y;
}

// ---------------------------------------------------------------- 钩子
typedef OSStatus (*RenderFn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                             UInt32, UInt32, AudioBufferList *);
typedef void (*HookFn)(void *, void *, void **);

static RenderFn gOrigRender = NULL;
static double   gSampleRate  = 44100.0;

static void feed(float *p, int n) {
    // 取最新 512 帧足够（按 44100Hz ≈ 11.6ms）
    if (gSampleRate < 8000) bands_init(gSampleRate);

    // 自动量程：第一次调用时看样本幅度，> 1.5 视为 int16 原始值
    if (gInScale == 0.0) {
        double mx = 0.0;
        for (int i = 0; i < n; i++) { double a = fabs((double)p[i]); if (a > mx) mx = a; }
        gInScale = (mx > 1.5) ? (1.0 / 32768.0) : 1.0;
    }
    double sc = gInScale;
    double acc[AXS_BANDS];
    for (int i = 0; i < AXS_BANDS; i++) acc[i] = 0.0;
    for (int k = 0; k < n; k++) {
        double x = (double)p[k] * sc;
        for (int i = 0; i < AXS_BANDS; i++) {
            double y = bq_run(&gF[i], x);
            acc[i] += y * y;
        }
    }
    if (n <= 0) return;
    pthread_mutex_lock(&gLock);
    for (int i = 0; i < AXS_BANDS; i++) {
        double e = sqrt(acc[i] / (double)n);          // 段 RMS
        double db = 20.0 * log10(e + 1e-9);           // dBFS
        // -70..-6 dB 映射到 0..100，留出顶部余量，避免全部顶格
        double v  = (db + 70.0) / 64.0 * 100.0;
        if (v < 0) v = 0; if (v > 100) v = 100;
        // 上升快、回落慢
        gBand[i] = (v > gBand[i]) ? (gBand[i]*0.45 + v*0.55) : (gBand[i]*0.82 + v*0.18);
    }
    pthread_mutex_unlock(&gLock);
}

static OSStatus hookedRender(AudioUnit au, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts,
                             UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus st = gOrigRender(au, fl, ts, bus, frames, io);
    if (st == noErr && io && io->mNumberBuffers > 0) {
        AudioBuffer *b = &io->mBuffers[0];
        int n = frames;
        if (b->mData && n > 0) {
            gCalls++;
            gFrames += n;
            if (b->mNumberChannels > 1) {
                // 多通道：取第一通道
                if (b->mDataByteSize >= (UInt32)(n * sizeof(float) * b->mNumberChannels)) {
                    // 交错：抽第一通道
                    static float tmp[1024];
                    float *src = (float *)b->mData;
                    if (n > 1024) n = 1024;
                    for (int i = 0; i < n; i++) tmp[i] = src[i * b->mNumberChannels];
                    feed(tmp, n);
                }
            } else {
                if (n > 1024) n = 1024;
                feed((float *)b->mData, n);
            }
        }
    }
    return st;
}

// ---------------------------------------------------------------- TCP 服务
static int gListenFD = -1;

static void *srv_thread(void *arg) {
    (void)arg;
    mkdir(AXS_TMP, 0777);

    gListenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (gListenFD < 0) return NULL;
    int one = 1;
    setsockopt(gListenFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in ad; memset(&ad, 0, sizeof ad);
    ad.sin_family = AF_INET;
    ad.sin_port   = htons(AXS_PORT);
    ad.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(gListenFD, (struct sockaddr *)&ad, sizeof ad) < 0) { close(gListenFD); gListenFD = -1; return NULL; }
    if (listen(gListenFD, 4) < 0) { close(gListenFD); gListenFD = -1; return NULL; }
    fcntl(gListenFD, F_SETFL, O_NONBLOCK);
    gSrvOK = 1;

    int clients[4] = {-1,-1,-1,-1};
    char line[192];
    while (1) {
        int c = accept(gListenFD, NULL, NULL);
        if (c >= 0) {
            for (int i = 0; i < 4; i++) if (clients[i] < 0) { clients[i] = c; break; }
        }
        // 组装一行
        pthread_mutex_lock(&gLock);
        int n = snprintf(line, sizeof line, "AXS %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f\n",
                         gBand[0],gBand[1],gBand[2],gBand[3],gBand[4],
                         gBand[5],gBand[6],gBand[7],gBand[8],gBand[9]);
        pthread_mutex_unlock(&gLock);

        for (int i = 0; i < 4; i++) {
            if (clients[i] < 0) continue;
            if (send(clients[i], line, n, MSG_NOSIGNAL) <= 0) { close(clients[i]); clients[i] = -1; }
        }

        // 兜底文件
        FILE *f = fopen(AXS_LEVELS ".tmp", "w");
        if (f) {
            fputs(line, f); fclose(f);
            rename(AXS_LEVELS ".tmp", AXS_LEVELS);
            gWriteOK = 1;
        }
        usleep(33000);   // ≈30Hz
    }
    return NULL;
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

__attribute__((visibility("default"))) int axs_start(void) {
    if (gHookOK) return 0;

    static const char *substrates[] = {
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        NULL
    };
    HookFn hook = (HookFn)resolve(substrates, "MSHookFunction");
    if (!hook) return -10;

    void *au = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    void *sym = au ? dlsym(au, "AudioUnitRender") : NULL;
    if (!sym) sym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (!sym) return -11;

    // 采样率：优先问 AudioUnit，拿不到就用 44100
    gSampleRate = 44100.0;
    bands_init(gSampleRate);

    hook(sym, (void *)hookedRender, (void **)&gOrigRender);
    if (!gOrigRender) return -12;
    gHookOK = 1;

    pthread_t t;
    if (pthread_create(&t, NULL, srv_thread, NULL) == 0) pthread_detach(t);
    return 1;
}

__attribute__((visibility("default"))) int axs_stop(void) { gHookOK = 0; return 0; }
