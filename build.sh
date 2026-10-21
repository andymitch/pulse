#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pulse.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pulse "$APP/Contents/MacOS/Pulse"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Pulse.entitlements --sign "$DEVELOPER_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"

case "${1:-}" in
--install)
    pkill -x Pulse 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Pulse.app
    cp -R "$APP" /Applications/Pulse.app
    open /Applications/Pulse.app
    echo "Installed /Applications/Pulse.app"
    ;;
--release)
    if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
        ditto -c -k --keepParent "$APP" build/notarize.zip
        xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm build/notarize.zip
    fi
    ZIP="build/Pulse_aarch64.zip"
    DMG="build/Pulse_aarch64.dmg"
    rm -f "$ZIP" "$DMG"
    ditto -c -k --keepParent "$APP" "$ZIP"
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname Pulse -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
    if [[ -n "${PULSE_UPDATE_KEY:-}" ]]; then
        swift scripts/sign-update.swift "$ZIP" > "$ZIP.sig"
        echo "Signed $ZIP"
    fi
    echo "Packaged $ZIP and $DMG"
    ;;
esac
