//
//  AxsTcpLevels.m — 面板侧消费端：从 127.0.0.1:47923 读真实电平
//  用法：放进面板工程，在 pollLevels 开头调用：
//      float lv[10];
//      if (AxsTcpPollLevels(lv)) { /* 用 lv 画频谱 */ } else { /* 走旧的 fallback */ }
//
//  v2 修复（v1 的三个实际故障）：
//   1. 对端关闭（r == 0）时只 break、不 close：s_fd 从此永远失效，
//      recv 一直返回 0，面板电平永久冻结在最后一帧，且永不重连。
//      → 现在 r == 0 直接 close 并置 -1，下一帧自动重连。
//   2. 连接失败时每帧都 socket()+connect()：面板刷新 30Hz 时一秒 30 次系统调用。
//      → 现在失败后退避 500ms。
//   3. parseLatest 里来回找换行、失败就 strcpy(s_acc,"") 清空整个缓冲，
//      会把刚收到的后续数据一起丢掉。→ 重写为「取最后一个完整行 + 只保留残余半行」。
//

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

#define AXS_PORT      47923
#define AXS_RETRY_SEC 0.5

static int        s_fd      = -1;
static char       s_acc[8192];
static CFAbsoluteTime s_nextTry = 0;

// 从累积缓冲里取「最后一个完整行」并解析。
// 成功时 out 为 10 段电平，缓冲只保留最后一行之后的残余（半行）。
static BOOL parseLatest(float out[10]) {
    char *lastNL = strrchr(s_acc, '\n');
    if (!lastNL) return NO;                       // 还没有完整行

    char *start = lastNL;                         // 这一行的行首
    while (start > s_acc && start[-1] != '\n') start--;

    if ((size_t)(lastNL - start) < 4 || strncmp(start, "AXS", 3) != 0) {
        // 不是电平行（或残行），只丢掉这一行，不动其它数据
        memmove(s_acc, lastNL + 1, strlen(lastNL + 1) + 1);
        return NO;
    }

    float v[10];
    int got = sscanf(start + 3, "%f %f %f %f %f %f %f %f %f %f",
                     &v[0],&v[1],&v[2],&v[3],&v[4],&v[5],&v[6],&v[7],&v[8],&v[9]);

    memmove(s_acc, lastNL + 1, strlen(lastNL + 1) + 1);   // 只留残余半行

    if (got != 10) return NO;
    for (int i = 0; i < 10; i++) out[i] = v[i];
    return YES;
}

static void axs_close(void) {
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
}

// 供面板在离开页面 / 切换输出设备时主动断开，避免半关闭套接字堆积
void AxsTcpResetLevels(void) {
    axs_close();
    s_acc[0] = 0;
    s_nextTry = 0;
}

static BOOL axs_connect(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < s_nextTry) return NO;               // 退避中

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { s_nextTry = now + AXS_RETRY_SEC; return NO; }

    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port   = htons(AXS_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        s_nextTry = now + AXS_RETRY_SEC;
        return NO;
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    s_fd = fd;
    s_acc[0] = 0;
    s_nextTry = 0;
    return YES;
}

// 非阻塞，随时可调；返回 YES 时 out 为 0..100 的 10 段电平
BOOL AxsTcpPollLevels(float out[10]) {
    if (s_fd < 0 && !axs_connect()) return NO;

    char buf[2048];
    for (;;) {
        ssize_t r = recv(s_fd, buf, sizeof(buf) - 1, 0);
        if (r > 0) {
            buf[r] = 0;
            size_t have = strlen(s_acc), add = (size_t)r;
            if (have + add + 1 > sizeof(s_acc)) {
                // 缓冲顶满（说明对端在灌数据但没换行）：丢掉最旧的一半，别丢新数据
                size_t keep = sizeof(s_acc) / 2;
                memmove(s_acc, s_acc + have - keep, keep);
                s_acc[keep] = 0;
                have = keep;
                if (have + add + 1 > sizeof(s_acc)) add = sizeof(s_acc) - 1 - have;
            }
            memcpy(s_acc + have, buf, add);
            s_acc[have + add] = 0;
            continue;                             // 把内核缓冲读空
        }
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (r == 0) {                              // 对端关闭：必须重连，否则永久冻结
            axs_close();
            s_nextTry = CFAbsoluteTimeGetCurrent() + AXS_RETRY_SEC;
            break;
        }
        // 其它错误
        axs_close();
        s_nextTry = CFAbsoluteTimeGetCurrent() + AXS_RETRY_SEC;
        break;
    }

    if (s_fd < 0) return NO;
    return parseLatest(out);
}
