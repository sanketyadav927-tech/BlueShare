TARGET  := iphone:clang:16.5:14.0
ARCHS   := arm64

include $(THEOS)/makefiles/common.mk

ADDITIONAL_CFLAGS := -Wno-error -Wno-objc-designated-initializers -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations

# ── Main Tweak ──────────────────────────────────────────────────────────────
TWEAK_NAME := BlueShare
BlueShare_FILES := \
    Tweak.xm \
    BTShareActivity.m \
    DevicePickerViewController.m \
    TransferManager.m

BlueShare_FRAMEWORKS  := UIKit CoreBluetooth CoreFoundation UserNotifications CoreImage
BlueShare_PRIVATE_FRAMEWORKS :=
BlueShare_CFLAGS      := -fobjc-arc -Wno-error -Wno-objc-designated-initializers -Wno-unused-variable
BlueShare_LDFLAGS     :=
BlueShare_LIBRARIES   :=

include $(THEOS_MAKE_PATH)/tweak.mk

# ── Background Daemon ────────────────────────────────────────────────────────
TOOL_NAME := BTShareDaemon
BTShareDaemon_FILES      := Daemon/main.m Daemon/DaemonTransferServer.m TransferManager.m
BTShareDaemon_FRAMEWORKS := CoreBluetooth Foundation UserNotifications UIKit
BTShareDaemon_CFLAGS     := -fobjc-arc -I$(THEOS_PROJECT_DIR) -Wno-error -Wno-objc-designated-initializers -Wno-unused-variable
BTShareDaemon_INSTALL_PATH := /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

# ── Preferences Pane ────────────────────────────────────────────────────────
BUNDLE_NAME := BlueSharePrefs
BlueSharePrefs_FILES      := Prefs/BSPrefsListController.m
BlueSharePrefs_FRAMEWORKS := UIKit QuartzCore
BlueSharePrefs_PRIVATE_FRAMEWORKS := Preferences
BlueSharePrefs_CFLAGS     := -fobjc-arc -Wno-error -Wno-objc-designated-initializers -Wno-unused-variable
BlueSharePrefs_INSTALL_PATH := /Library/PreferenceBundles
BlueSharePrefs_RESOURCES  := Prefs/Root.plist Prefs/entry.plist

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
	install.exec "launchctl unload /Library/LaunchDaemons/com.yourrepo.btsharedaemon.plist 2>/dev/null; \
	              launchctl load  /Library/LaunchDaemons/com.yourrepo.btsharedaemon.plist"
