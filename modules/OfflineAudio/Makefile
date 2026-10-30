TARGET := iphone:clang:latest:16.1
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Spotify
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = EeveeSpotify
EeveeSpotify_FILES = modules/OfflineAudio/OfflineOnly.x.swift
EeveeSpotify_SWIFTFLAGS = -Osize
include $(THEOS_MAKE_PATH)/tweak.mk
