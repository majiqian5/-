// IslandHLS v0.2 —— 灵动岛内播放 m3u8 / HLS（直播电视源）
// 适配：iOS 15~18 rootless（Dopamine / palera1n），只注入 SpringBoard
//
// v0.2 相对 v0.1 的关键修复：
//   1. 内置默认源（https，绕开 ATS），装完即播，不必先写 plist
//   2. 直播断流自愈：watchdog 检测卡顿 + item 失败，指数退避重建 item
//   3. 播放失败有明确日志（含 -1022 / 403 判定提示），便于定位
//   4. 出声支持：muted=false 时配置 AVAudioSession playback
//   5. 多源（urls 数组）：连续失败自动换下一个源，可定时轮播
//   6. 窗口挂 rootViewController，避免不显示 / 被系统回收
//   7. 观察者全部成对释放，反复 setup 不泄漏

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#define kPrefPath   @"/var/mobile/Library/Preferences/com.you.islandhls.plist"
#define kLogPath    @"/var/mobile/Documents/IslandHLS.log"

// 默认源：上虞新闻综合（https，免 ATS）
#define kDefaultURL @"https://l.cztvcloud.com/channels/lantian/SXshangyu1/720p.m3u8"

static UIWindow         *gWindow   = nil;
static UIViewController *gRootVC   = nil;
static AVPlayer         *gPlayer   = nil;
static AVPlayerLayer    *gLayer    = nil;
static id                gEndObs   = nil;
static id                gFailObs  = nil;
static id                gErrLogObs= nil;
static NSTimer          *gWatchdog = nil;
static NSTimer          *gRetry    = nil;
static NSTimer          *gRotate   = nil;

static NSArray          *gSources  = nil;
static NSUInteger        gIndex    = 0;
static int               gRetryStep= 0;
static int               gFailStreak = 0;
static double            gLastPos  = -1.0;
static CFTimeInterval    gLastMove = 0;
static BOOL              gBooted   = NO;

// ==================== 日志 ====================
// 先保证目录存在：/var/mobile/Documents 在某些精简系统上不存在，
// 目录缺失会导致 fopen 静默失败 → 一条日志都写不出来，看起来就像"没装"。
static void EnsureLogDir(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents"
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
}

static void ILog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    NSLog(@"[IslandHLS] %@", s);

    static BOOL dirOk = NO;
    if (!dirOk) { EnsureLogDir(); dirOk = YES; }

    NSFileManager *fm = [NSFileManager defaultManager];
    // 简单限长：超过 512KB 直接清空，避免无限增长
    NSDictionary *attr = [fm attributesOfItemAtPath:kLogPath error:nil];
    if ([attr fileSize] > 512 * 1024) [fm removeItemAtPath:kLogPath error:nil];

    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

// ==================== 配置 ====================
static NSDictionary *Cfg(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    return d ?: @{};
}
static id C(NSString *k, id def) {
    id v = Cfg()[k];
    return v ? v : def;
}

// 14 Pro / Pro Max / 15 / 16 系列默认 126pt × 37pt，顶部约 11pt；可用 plist 覆盖
static CGRect IslandRect(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat w = [C(@"width",  @(126.0)) doubleValue];
    CGFloat h = [C(@"height", @(37.0))  doubleValue];
    CGFloat y = [C(@"top",    @(11.0))  doubleValue];
    return CGRectMake((b.size.width - w) / 2.0, y, w, h);
}

static UIWindowScene *ActiveScene(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

// ==================== 清理 ====================
static void StopIslandHLS(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (gEndObs)    { [nc removeObserver:gEndObs];    gEndObs = nil; }
    if (gFailObs)   { [nc removeObserver:gFailObs];   gFailObs = nil; }
    if (gErrLogObs) { [nc removeObserver:gErrLogObs]; gErrLogObs = nil; }

    [gWatchdog invalidate]; gWatchdog = nil;
    [gRetry invalidate];    gRetry    = nil;
    [gRotate invalidate];   gRotate   = nil;

    [gPlayer pause];
    [gPlayer replaceCurrentItemWithPlayerItem:nil];
    gPlayer = nil;
    [gLayer removeFromSuperlayer];
    gLayer = nil;

    gWindow.hidden = YES;
    gWindow.rootViewController = nil;
    gWindow = nil;
    gRootVC = nil;

    gLastPos = -1.0;
    gLastMove = 0;
    gFailStreak = 0;
}

// ==================== 重试 ====================
static void Setup(void);

static void ScheduleRetry(NSString *why) {
    if (gRetry) return;                       // 已经在排队
    if (!gSources.count) return;

    // 连续失败 3 次就换下一个源（多源才有意义）
    gFailStreak++;
    if (gFailStreak >= 3 && gSources.count > 1) {
        gIndex = (gIndex + 1) % gSources.count;
        gFailStreak = 0;
        ILog(@"连续失败，切到源 #%lu: %@", (unsigned long)gIndex, gSources[gIndex]);
    }

    double delay = 2.0;
    for (int i = 0; i < gRetryStep && i < 5; i++) delay *= 2.0;   // 2,4,8,16,32
    if (delay > 30.0) delay = 30.0;
    gRetryStep++;

    ILog(@"准备重连 #%d，%.0fs 后（原因：%@）", gRetryStep, delay, why);
    NSArray *srcs = gSources;
    NSUInteger idx = gIndex;
    gRetry = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        gRetry = nil;
        if (gSources != srcs) return;          // 期间配置变了，放弃这次
        gIndex = idx;
        Setup();
    }];
}

// 直播卡死 / item 失败 的探针，每 4 秒扫一次
static void WatchTick(void) {
    if (!gPlayer) return;
    AVPlayerItem *item = gPlayer.currentItem;
    if (!item) return;

    if (item.status == AVPlayerItemStatusFailed) {
        ILog(@"item 失败: %@", item.error);
        ScheduleRetry([NSString stringWithFormat:@"item.status=Failed %@", item.error.localizedDescription ?: @""]);
        return;
    }

    double pos = CMTimeGetSeconds(gPlayer.currentTime);
    CFTimeInterval now = CACurrentMediaTime();

    if (!isfinite(pos)) return;
    if (pos != gLastPos) {                     // 时间轴在走，说明活着
        gLastPos  = pos;
        gLastMove = now;
        gRetryStep = 0;
        return;
    }
    if (gLastMove > 0 && (now - gLastMove) > 12.0) {   // 12 秒原地不动 = 断流
        ILog(@"检测到卡死 12s（pos=%.1f，状态=%ld），重建", pos, (long)gPlayer.timeControlStatus);
        ScheduleRetry(@"播放器卡死 12s");
    }
}

// ==================== 启动 ====================
static void StartIslandHLS(void) {
    NSDictionary *cfg = Cfg();

    // 源列表：优先 urls 数组，其次 url，最后内置默认
    id urls = cfg[@"urls"];
    if ([urls isKindOfClass:[NSArray class]] && [urls count]) {
        gSources = urls;
    } else {
        NSString *u = cfg[@"url"];
        gSources = @[ u.length ? u : kDefaultURL ];
    }
    if (gIndex >= gSources.count) gIndex = 0;
    NSString *urlStr = gSources[gIndex];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || !url.scheme) { ILog(@"url 非法: %@", urlStr); return; }

    // ATS 预警：明文 http 在 SpringBoard 里大概率被拦（错误码 -1022）
    if ([url.scheme isEqualToString:@"http"]) {
        ILog(@"注意：当前是 http 明文源，若拉流失败且错误码为 -1022，即 ATS 拦截，建议换 https 或装 ATS 豁免");
    }

    // 自定义头（防盗链源必填）
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if ([cfg[@"user_agent"] length]) headers[@"User-Agent"] = cfg[@"user_agent"];
    if ([cfg[@"referer"] length])    headers[@"Referer"]    = cfg[@"referer"];
    if ([cfg[@"cookie"] length])     headers[@"Cookie"]     = cfg[@"cookie"];

    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (headers.count) opts[@"AVURLAssetHTTPHeaderFieldsKey"] = headers;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:opts];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];

    // 直播低延迟（可选）：缩短前向缓冲，减少“卡在旧分片”
    if ([C(@"low_latency", @(NO)) boolValue]) {
        item.preferredForwardBufferDuration = 2.0;
    }

    BOOL muted = [C(@"muted", @(NO)) boolValue];
    if (!muted) {
        NSError *err = nil;
        AVAudioSession *sess = [AVAudioSession sharedInstance];
        [sess setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&err];
        [sess setActive:YES error:&err];
        if (err) ILog(@"音频会话设置失败: %@", err);
    }

    UIWindowScene *scene = ActiveScene();
    if (!scene) ILog(@"拿不到前台 UIWindowScene，退回传统窗口（不影响显示）");

    CGRect rect = IslandRect();

    gRootVC = [[UIViewController alloc] init];
    gRootVC.view.backgroundColor = [UIColor colorWithRed:0.55 green:0.04 blue:0.04 alpha:1.0];
    gRootVC.view.userInteractionEnabled = NO;

    // 两种建法：有 scene 用 scene 版，没有就退回 frame 版（原来死在这条上会整块不显示）
    if (scene) {
        gWindow = [[UIWindow alloc] initWithWindowScene:scene];
        gWindow.frame = rect;
    } else {
        gWindow = [[UIWindow alloc] initWithFrame:rect];
    }
    // 可见性探针：先铺 1 秒深红底。岛上闪红 = 窗口能显示；不闪 = 没注入/没显示
    gWindow.backgroundColor = [UIColor colorWithRed:0.55 green:0.04 blue:0.04 alpha:1.0];
    // 默认压过系统所有窗口（10000001）；原来 StatusBar+1 在部分系统版本上会掉到岛下面
    gWindow.windowLevel = [C(@"level", @(10000001.0)) doubleValue];
    gWindow.userInteractionEnabled = NO;          // 不吃触摸，不抢岛手势
    gWindow.rootViewController = gRootVC;
    gWindow.clipsToBounds = YES;
    gWindow.layer.cornerRadius = rect.size.height / 2.0;
    gWindow.layer.cornerCurve = kCACornerCurveContinuous;
    gWindow.layer.masksToBounds = YES;
    gWindow.hidden = NO;
    [gWindow setHidden:NO];
    ILog(@"窗口已建立 level=%.0f scene=%@ rect=%@", gWindow.windowLevel, scene ? @"yes" : @"no", NSStringFromCGRect(rect));
    gWindow.userInteractionEnabled = NO;          // 不吃触摸，不抢岛手势
    gWindow.rootViewController = gRootVC;
    gWindow.clipsToBounds = YES;
    gWindow.layer.cornerRadius = rect.size.height / 2.0;
    gWindow.layer.cornerCurve = kCACornerCurveContinuous;
    gWindow.layer.masksToBounds = YES;
    gWindow.hidden = NO;

    gPlayer = [AVPlayer playerWithPlayerItem:item];
    gPlayer.muted = muted;
    gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    gPlayer.automaticallyWaitsToMinimizeStalling = YES;

    gLayer = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
    gLayer.frame = gRootVC.view.bounds;
    gLayer.videoGravity = [C(@"gravity", @"fill") isEqualToString:@"fit"]
        ? AVLayerVideoGravityResizeAspect
        : AVLayerVideoGravityResizeAspectFill;
    [gRootVC.view.layer addSublayer:gLayer];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // 点播片尾循环；直播（duration 无限）不会走这里，避免乱 seek
    gEndObs = [nc addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                              object:item queue:[NSOperationQueue mainQueue]
                          usingBlock:^(NSNotification *n) {
        double d = CMTimeGetSeconds(item.duration);
        if (isfinite(d) && d > 0) {
            ILog(@"片尾，循环重播");
            [item seekToTime:kCMTimeZero completionHandler:nil];
            [gPlayer play];
        } else {
            ILog(@"直播流播完（可能是 EVENT 型播放列表），重建");
            ScheduleRetry(@"直播播放列表结束");
        }
    }];

    gFailObs = [nc addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                               object:item queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification *n) {
        NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
        ILog(@"播放失败: code=%ld %@", (long)e.code, e.localizedDescription);
        ScheduleRetry([NSString stringWithFormat:@"failedToPlayToEnd %ld", (long)e.code]);
    }];

    // 分片级错误日志，能看出 403 / 404 / 超时
    gErrLogObs = [nc addObserverForName:AVPlayerItemNewErrorLogEntryNotification
                                 object:item queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification *n) {
        AVPlayerItemErrorLogEvent *ev = item.errorLog.events.lastObject;
        if (ev) ILog(@"分片错误: status=%ld uri=%@ comment=%@", (long)ev.errorStatusCode, ev.URI, ev.errorComment);
    }];

    [gPlayer play];

    // 探针收尾：0.8 秒后转黑，避免一直红着
    UIWindow *wProbe = gWindow;
    UIViewController *vcProbe = gRootVC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (wProbe && wProbe == gWindow) {
            wProbe.backgroundColor = [UIColor blackColor];
            vcProbe.view.backgroundColor = [UIColor blackColor];
            ILog(@"窗口已显示：探针转黑（若你看到过红光，说明注入与显示都正常）");
        }
    });

    gLastPos = -1.0;
    gLastMove = CACurrentMediaTime();
    gRetryStep = 0;
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *t) { WatchTick(); }];

    // 定时轮播（多个源 + rotate_seconds > 0 时启用）
    double rots = [C(@"rotate_seconds", @(0.0)) doubleValue];
    if (rots > 0 && gSources.count > 1) {
        gRotate = [NSTimer scheduledTimerWithTimeInterval:rots repeats:YES block:^(NSTimer *t) {
            gIndex = (gIndex + 1) % gSources.count;
            ILog(@"轮播切到源 #%lu", (unsigned long)gIndex);
            Setup();
        }];
    }

    ILog(@"启动 #%lu url=%@ rect=%@ muted=%d", (unsigned long)gIndex, urlStr, NSStringFromCGRect(rect), muted);
}

static void Setup(void) {
    StopIslandHLS();
    StartIslandHLS();
}

// ==================== 热重启 / 配置变更 ====================
static void OnChanged(CFNotificationCenterRef c, void *obs, CFStringRef name,
                      const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ILog(@"收到变更通知，热重启");
        Setup();
    });
}

// ==================== 入口 ====================
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    if (gBooted) return;
    gBooted = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Setup(); });
}
%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                   NULL, OnChanged,
                                   CFSTR("com.you.islandhls/changed"),
                                   NULL,
                                   CFNotificationSuspensionBehaviorDeliverImmediately);
    ILog(@"tweak 已加载 pid=%d", getpid());

    // 兜底：万一 applicationDidFinishLaunching 钩不到（某些版本 SpringBoard 结构变了），
    // 3 秒后自己起一次；StartIslandHLS 里 gWindow 已存在则先 Stop，幂等。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gBooted) { gBooted = YES; Setup(); }
    });
}
