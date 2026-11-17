TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_PACKAGE_SCHEME = rootless
THEOS_PACKAGE_INSTALL_PREFIX = /var/jb

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IslandHLS
IslandHLS_FILES = Tweak.xm
IslandHLS_CFLAGS = -fobjc-arc
IslandHLS_FRAMEWORKS = UIKit AVFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
