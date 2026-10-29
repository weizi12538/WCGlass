TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

# 用 library 而非 tweak:不链接 CydiaSubstrate,生成的 dylib 可直接注入(lcsign)
LIBRARY_NAME = WCGlass
WCGlass_FILES = Tweak.m
WCGlass_FRAMEWORKS = UIKit Foundation
WCGlass_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-undeclared-selector
WCGlass_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
