/* axs_lv.c — 设备上读取真实电平的命令行小工具（v2）
 *
 * 编译（越狱机上或交叉编译）：
 *   xcrun --sdk iphoneos clang -target arm64e-apple-ios15.0 -O2 -o axs_lv axs_lv.c
 *   ldid -Sent.plist axs_lv      # 需要 platform-application，否则 zsh: killed
 *
 * 用法：
 *   axs_lv         连续打印 20 行
 *   axs_lv 60      打印 60 行
 *
 * v2 改动：
 *   - 加 SO_RCVTIMEO：对端不发数据时不会永久卡死（v1 会 hang，看起来像"工具挂了"）
 *   - 按行切分输出，一次 recv 收到多行时不会挤成一行
 *   - 退出码区分「连不上」和「连上但没数据」，方便脚本判断
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PORT 47923

int main(int argc, char **argv) {
    int want = (argc > 1) ? atoi(argv[1]) : 20;
    if (want <= 0) want = 20;

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 2; }

    struct timeval tv = { 2, 0 };                 // 2s 接收超时
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port   = htons(PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
        fprintf(stderr, "connect 127.0.0.1:%d 失败: %s\n", PORT, strerror(errno));
        fprintf(stderr, "→ 载荷没起来？先在 EQE 控制台 dofile axs_load.lua 看 status bit1\n");
        close(s);
        return 1;
    }

    char buf[512];
    char line[512];
    size_t have = 0;
    int printed = 0;

    while (printed < want) {
        ssize_t r = recv(s, buf, sizeof(buf), 0);
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                fprintf(stderr, "接收超时（2s 无数据）: 钩子在但没在分析，看 status bit0 / calls\n");
                close(s);
                return 3;
            }
            perror("recv");
            close(s);
            return 4;
        }
        if (r == 0) { fprintf(stderr, "对端关闭\n"); break; }

        for (ssize_t i = 0; i < r; i++) {
            if (buf[i] == '\n') {
                line[have] = 0;
                printf("%s\n", line);
                have = 0;
                if (++printed >= want) break;
            } else if (have < sizeof(line) - 1) {
                line[have++] = buf[i];
            }
        }
        fflush(stdout);
    }
    close(s);
    return 0;
}
