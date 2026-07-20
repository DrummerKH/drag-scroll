#!/bin/bash
# Builds DragScroll.app using clang + Command Line Tools (no full Xcode required).
# For a signed/release build, open DragScroll.xcodeproj in Xcode instead.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DragScroll"
BUNDLE_ID="com.emreyolcu.DragScroll"
VERSION="1.4.1"
BUILD_NUM="7"
MIN_MACOS="10.13"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "Compiling..."
clang -fobjc-arc -fmodules \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$MIN_MACOS" \
    -Wall -O2 \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework Carbon \
    DragScroll/main.m \
    -o "$MACOS_DIR/$APP_NAME"

echo "Assembling bundle..."
cp DragScroll/AppIcon.icns "$RES_DIR/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUM</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign so the app has a stable identity for Accessibility / login item.
codesign --force --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Built $APP"
