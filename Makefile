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

# ---------------------------------------------------------------- AX service app
# A real GUI process, so it inherits the user session bootstrap and can reach
# com.apple.iphone.axserver -- which a root daemon cannot on iOS 17.
# Built as a `tool` whose install path happens to be the .app's executable slot;
# Info.plist comes from layout/Applications/UIBridgeSvc.app/Info.plist.
TOOL_NAME = UIBridgeSvc
UIBridgeSvc_FILES = app/main.m src/AXBridge.m src/HIDInjector.m src/LCServer.m src/LCCommands.m src/UBAgentHub.m
UIBridgeSvc_CFLAGS = -fobjc-arc -Isrc -Wno-deprecated-declarations
UIBridgeSvc_FRAMEWORKS = Foundation CoreFoundation UIKit AVFoundation
UIBridgeSvc_LDFLAGS = -lobjc
UIBridgeSvc_INSTALL_PATH = /Applications/UIBridgeSvc.app
UIBridgeSvc_CODESIGN_FLAGS = -S$(CURDIR)/app-entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk

# ---------------------------------------------------------------- post-install
# Respring must be done as `mobile`: root's killall makes SpringBoard come back
# without the tweak injection environment.
after-install::
	install.exec "su mobile -c 'killall -9 SpringBoard' 2>/dev/null; launchctl bootout system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null; launchctl kickstart -k system/com.yg.uibridge 2>/dev/null; /var/jb/usr/bin/uicache -p /var/jb/Applications/UIBridgeSvc.app 2>/dev/null; true"
