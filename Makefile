export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64
# non-interactive shells do not always inherit the Homebrew prefix, and Theos
# needs ldid from PATH to apply our entitlements
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
# keep the clang module cache inside the checkout (sandboxed builds cannot write /var/folders)
export CLANG_MODULE_CACHE_PATH = $(CURDIR)/.modulecache
export TMPDIR = $(CURDIR)/.tmp

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- per-app agent tweak
# Injected into every process that owns a UIApplication. On iOS 17 this is the only
# way to read another app's view tree: axserver lives in the user bootstrap domain and
# a root daemon cannot reach it.
TWEAK_NAME = UIBridgeAgent
UIBridgeAgent_FILES = tweak/UIBridgeAgent.xm
UIBridgeAgent_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
UIBridgeAgent_FRAMEWORKS = Foundation UIKit CoreGraphics
UIBridgeAgent_LDFLAGS = -lobjc

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------- launchd daemon
TOOL_NAME = uibridge
uibridge_FILES = src/main.m src/AXBridge.m src/HIDInjector.m src/LCServer.m src/LCCommands.m src/UBAgentHub.m
uibridge_CFLAGS = -fobjc-arc -Isrc -Wno-deprecated-declarations
uibridge_FRAMEWORKS = Foundation CoreFoundation
uibridge_LDFLAGS = -lobjc
uibridge_INSTALL_PATH = /usr/libexec
uibridge_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null; launchctl bootout system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null; launchctl kickstart -k system/com.yg.uibridge 2>/dev/null; true"
