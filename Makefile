# Theos 构建 —— 仅用于语法/链接参考，产物不可用！
#
# 原因（别再试了）：
#   Linux/macOS 上的 Theos clang 出 arm64e 时不会生成指针认证（PAC）代码，
#   产物 Mach-O 头是 cpusubtype=2 但没有 caps=0x80（ABI v2 标记）。
#   手改头能过 dlopen，但一调用 MSHookFunction / pthread_create
#   就触发 ptrauth 失败 → mediaserverd 立即被 kill。
#
#   必须：macOS + 完整 Xcode 的 Apple clang，用 ./build_xcode.sh。
#   make 编出来的东西只用来确认 .m 能过编译、符号能导出。

TARGET := iphone:clang:16.4:15.0
ARCHS  := arm64e arm64
INSTALL_TARGET_PROCESSES := mediaserverd

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AxsLevel
AxsLevel_FILES = AxsLevel.m
AxsLevel_FRAMEWORKS = Foundation AudioToolbox
AxsLevel_CFLAGS = -fobjc-arc -O2 -Wall
AxsLevel_INSTALL_PATH = /Library/AxsEQ

include $(THEOS_MAKE_PATH)/library.mk
