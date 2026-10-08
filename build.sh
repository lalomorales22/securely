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
# Signing identity: $SIGN_ID, else an Apple Development cert, else a local "Securely Local Signing" cert, else ad-hoc.
IDS=$(security find-identity -p codesigning)
if [ -n "${SIGN_ID:-}" ]; then SIGN="$SIGN_ID"
elif echo "$IDS" | grep -q "Apple Development"; then SIGN=$(echo "$IDS" | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
elif echo "$IDS" | grep -q "Securely Local Signing"; then SIGN="Securely Local Signing"
else SIGN="-"; echo "warning: no stable identity, using ad-hoc (Keychain will re-prompt after every rebuild)"; fi
echo "Signing with: $SIGN"
codesign --force --deep --sign "$SIGN" $APP || { echo "codesign failed; retrying with the local identity or ad-hoc"; codesign --force --deep --sign "Securely Local Signing" $APP 2>/dev/null || codesign --force --deep --sign - $APP; }
echo "Built $APP"
