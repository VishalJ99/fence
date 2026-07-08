#!/bin/bash
set -e

# Configuration
APP_NAME="Fence"
BUNDLE_ID="org.eyebeam.Fence"
DEVELOPER_ID="Developer ID Application: Vishal Jain (L5YX8CH3F5)"
TEAM_ID="L5YX8CH3F5"
APPLE_ID="jainvishal2212@gmail.com"  # Your Apple ID
VERSION="${1:-1.0}"

# Paths
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
BUILD_DIR="$DERIVED_DATA/Build/Products/Release"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/Fence.app"
DMG_NAME="Fence-$VERSION.dmg"
ZIP_NAME="Fence-$VERSION.zip"
ENTITLEMENTS_PATH="$PROJECT_DIR/build/FenceRelease.entitlements"

echo "=== Building Fence v$VERSION ==="

# Prepare generated release metadata before Xcode scans precompiled headers.
echo "→ Preparing release metadata..."
echo "#define SELFCONTROL_VERSION_STRING @\"$VERSION\"" > "$PROJECT_DIR/version-header.h"
mkdir -p "$(dirname "$ENTITLEMENTS_PATH")"
cat > "$ENTITLEMENTS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>${TEAM_ID}.${BUNDLE_ID}</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array/>
    <key>com.apple.developer.team-identifier</key>
    <string>${TEAM_ID}</string>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>${TEAM_ID}.${BUNDLE_ID}</string>
    <key>keychain-access-groups</key>
    <array>
        <string>${TEAM_ID}.app.usefence.license</string>
    </array>
</dict>
</plist>
EOF

# Clean and build
echo "→ Building release..."
cd "$PROJECT_DIR"
xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -arch arm64 \
    CODE_SIGNING_ALLOWED=NO \
    clean build | tail -20

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi
echo "✓ Build complete"

# Sign all components with hardened runtime
echo "→ Signing app components..."

# Sign Sparkle framework internals first (deepest first)
find "$APP_PATH/Contents/Frameworks/Sparkle.framework" -type f \( -name "*.app" -o -perm +111 \) | while read binary; do
    echo "  Signing: $binary"
    codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp "$binary" 2>/dev/null || true
done

# Sign Sparkle Autoupdate.app bundle
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app" ]; then
    echo "  Signing: Autoupdate.app"
    codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app"
fi

# Sign Sparkle framework
echo "  Signing: Sparkle.framework"
codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Sign the privileged helper/daemon
if [ -f "$APP_PATH/Contents/Library/LaunchServices/org.eyebeam.selfcontrold" ]; then
    echo "  Signing: org.eyebeam.selfcontrold"
    codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
        "$APP_PATH/Contents/Library/LaunchServices/org.eyebeam.selfcontrold"
fi

# Sign helper executables in MacOS
for helper in "$APP_PATH/Contents/MacOS/"*; do
    if [ -f "$helper" ] && [ -x "$helper" ]; then
        echo "  Signing: $(basename "$helper")"
        codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp "$helper"
    fi
done

# Finally sign the main app bundle
echo "  Signing: Fence.app"
codesign --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

# Verify signature
echo "→ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "✓ App signed"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create ZIP for notarization
echo "→ Creating ZIP for notarization..."
cd "$BUILD_DIR"
rm -f "$OUTPUT_DIR/$ZIP_NAME"
ditto -c -k --keepParent "Fence.app" "$OUTPUT_DIR/$ZIP_NAME"

# Notarize
echo "→ Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$OUTPUT_DIR/$ZIP_NAME" \
    --keychain-profile "AC_PASSWORD" \
    --wait

# Staple the ticket
echo "→ Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
echo "✓ Notarization complete"

# Create DMG
echo "→ Creating DMG..."
rm -f "$OUTPUT_DIR/$DMG_NAME"
create-dmg \
    --volname "Fence" \
    --window-size 500 320 \
    --icon-size 80 \
    --icon "Fence.app" 125 150 \
    --app-drop-link 375 150 \
    "$OUTPUT_DIR/$DMG_NAME" \
    "$APP_PATH"
echo "✓ DMG created"

# Sign the DMG
echo "→ Signing DMG..."
codesign --sign "$DEVELOPER_ID" "$OUTPUT_DIR/$DMG_NAME"
echo "✓ DMG signed"

# Notarize the DMG too
echo "→ Notarizing DMG..."
xcrun notarytool submit "$OUTPUT_DIR/$DMG_NAME" \
    --keychain-profile "AC_PASSWORD" \
    --wait

xcrun stapler staple "$OUTPUT_DIR/$DMG_NAME"
echo "✓ DMG notarized"

# Final ZIP (for Sparkle updates)
echo "→ Creating final ZIP for Sparkle..."
cd "$BUILD_DIR"
rm -f "$OUTPUT_DIR/$ZIP_NAME"
ditto -c -k --keepParent "Fence.app" "$OUTPUT_DIR/$ZIP_NAME"

# Show Sparkle signature info
echo ""
echo "=== Build Complete ==="
echo "DMG: $OUTPUT_DIR/$DMG_NAME"
echo "ZIP: $OUTPUT_DIR/$ZIP_NAME"
echo ""
echo "For Sparkle appcast, run:"
echo "  ./Sparkle/bin/sign_update \"$OUTPUT_DIR/$ZIP_NAME\""
