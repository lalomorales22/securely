#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Securely.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
cp .build/release/Securely .build/release/securely-mcp $APP/Contents/MacOS/
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Securely</string>
<key>CFBundleIdentifier</key><string>ai.securely.app</string>
<key>CFBundleExecutable</key><string>Securely</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRequiresAquaSystemAppearance</key><false/>
</dict></plist>
PL
ID="Securely Local Signing"
if security find-identity -p codesigning | grep -q "$ID"; then SIGN="$ID"; else SIGN="-"; echo "warning: no stable identity, using ad-hoc (Keychain will re-prompt)"; fi
codesign --force --deep --sign "$SIGN" $APP
echo "Built $APP"
