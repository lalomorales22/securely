#!/bin/zsh
# Builds Securely through Xcode with automatic signing (provisioning profile + keychain entitlement).
# This is the only build that can use the hardware-bound (biometry-protected) Keychain mode.
# Prereqs: Xcode signed in with your Apple ID, an Apple Development certificate, and `tuist` (brew install tuist).
# Edit DEVELOPMENT_TEAM and the bundle ID in Project.swift / Securely.entitlements to match your own account.
set -e
cd "$(dirname "$0")"
tuist generate --no-open
xcodebuild -project Securely.xcodeproj -scheme Securely -configuration Release \
  -derivedDataPath .xbuild -allowProvisioningUpdates build | tail -3
rm -rf Securely.app
cp -R .xbuild/Build/Products/Release/Securely.app .
codesign --verify --deep --strict Securely.app && echo "Built Securely.app (signed, verified)"
