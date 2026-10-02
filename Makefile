TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AppMaskCalc
AppMaskCalc_FILES = Tweak.x
AppMaskCalc_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AppMaskCalc_FRAMEWORKS = UIKit Foundation
AppMaskCalc_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
