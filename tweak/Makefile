TARGET := iphone:clang:16.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = OfflineOnly
OfflineOnly_FILES = OfflineOnly.m
OfflineOnly_FRAMEWORKS = Foundation
OfflineOnly_CFLAGS = -fobjc-arc -O2
OfflineOnly_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
