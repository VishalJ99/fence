#!/bin/bash
set -eo pipefail

# Configuration
APP_NAME="Fence"
BUNDLE_ID="org.eyebeam.Fence"
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
PROFILE_PATH="${FENCE_RELEASE_PROFILE_PATH:-$PROJECT_DIR/FenceDirectDistribution.provisionprofile}"
SIGNING_KEYCHAIN="${FENCE_RELEASE_KEYCHAIN_PATH:-}"
SIGNING_KEYCHAIN_PASSWORD_FILE="${FENCE_RELEASE_KEYCHAIN_PASSWORD_FILE:-}"
SPARKLE_PRIVATE_KEY_PATH="${FENCE_SPARKLE_PRIVATE_KEY_PATH:-}"
DEVELOPER_ID_SHA1="${FENCE_DEVELOPER_ID_SHA1:-}"
CODESIGN_KEYCHAIN_ARGS=()
CREATE_DMG_ARGS=()
SIGNING_KEYCHAIN_UNLOCKED_BY_SCRIPT=0
PROFILE_PLIST=""

unlock_signing_keychain() {
    if [[ -n "$SIGNING_KEYCHAIN_PASSWORD_FILE" &&
          "$SIGNING_KEYCHAIN_UNLOCKED_BY_SCRIPT" -eq 0 ]]; then
        # Set this before unlocking so the EXIT trap still locks the Keychain if
        # the helper is interrupted after SecKeychainUnlock succeeds.
        SIGNING_KEYCHAIN_UNLOCKED_BY_SCRIPT=1
        if ! /usr/bin/xcrun swift "$PROJECT_DIR/scripts/unlock-release-keychain.swift" \
            "$SIGNING_KEYCHAIN" "$SIGNING_KEYCHAIN_PASSWORD_FILE"; then
            echo "❌ Unable to unlock the configured signing keychain."
            return 1
        fi
    fi
}

lock_signing_keychain() {
    if [[ "$SIGNING_KEYCHAIN_UNLOCKED_BY_SCRIPT" -eq 1 ]]; then
        if ! /usr/bin/security lock-keychain "$SIGNING_KEYCHAIN"; then
            echo "❌ Unable to re-lock the configured signing keychain." >&2
            return 1
        fi
        SIGNING_KEYCHAIN_UNLOCKED_BY_SCRIPT=0
    fi
}

cleanup_release_state() {
    local original_status=$?
    local cleanup_status=0
    trap - EXIT

    if [[ -n "$PROFILE_PLIST" && -f "$PROFILE_PLIST" ]]; then
        /bin/rm -f "$PROFILE_PLIST" || cleanup_status=1
    fi
    if ! lock_signing_keychain; then
        cleanup_status=1
    fi

    if [[ "$original_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
        original_status="$cleanup_status"
    fi
    exit "$original_status"
}

trap cleanup_release_state EXIT

DEVELOPER_ID_SHA1="$(printf '%s' "$DEVELOPER_ID_SHA1" | /usr/bin/tr '[:lower:]' '[:upper:]' | /usr/bin/tr -d ':[:space:]')"
if [[ "${#DEVELOPER_ID_SHA1}" -ne 40 || "$DEVELOPER_ID_SHA1" == *[!0-9A-F]* ]]; then
    echo "❌ FENCE_DEVELOPER_ID_SHA1 must be an exact 40-hex certificate fingerprint."
    exit 1
fi
DEVELOPER_ID="$DEVELOPER_ID_SHA1"

if [[ "$PROFILE_PATH" != /* ]]; then
    echo "❌ FENCE_RELEASE_PROFILE_PATH must be an absolute path."
    exit 1
fi
if [[ ! -f "$PROFILE_PATH" ]]; then
    echo "❌ Direct Distribution provisioning profile not found."
    echo "   Set FENCE_RELEASE_PROFILE_PATH to the matching profile."
    exit 1
fi

PROFILE_PLIST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/fence-release-profile.XXXXXX")"
if ! /usr/bin/security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"; then
    echo "❌ Unable to decode the Direct Distribution provisioning profile."
    exit 1
fi

profile_app_identifier="$(/usr/bin/plutil \
    -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
if [[ "$profile_app_identifier" != "$TEAM_ID.$BUNDLE_ID" ]]; then
    echo "❌ Direct Distribution profile does not authorize $TEAM_ID.$BUNDLE_ID."
    exit 1
fi

profile_certificate_matches=0
profile_certificate_count=0
while certificate_data="$(/usr/bin/plutil \
    -extract "DeveloperCertificates.$profile_certificate_count" raw -o - "$PROFILE_PLIST" 2>/dev/null)"; do
    certificate_fingerprint="$(printf '%s' "$certificate_data" | \
        /usr/bin/base64 -D | \
        /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 | \
        /usr/bin/sed -e 's/^.*=//' -e 's/://g')"
    if [[ "$certificate_fingerprint" == "$DEVELOPER_ID_SHA1" ]]; then
        profile_certificate_matches=$((profile_certificate_matches + 1))
    fi
    profile_certificate_count=$((profile_certificate_count + 1))
done
if [[ "$profile_certificate_count" -eq 0 || "$profile_certificate_matches" -ne 1 ]]; then
    echo "❌ Direct Distribution profile does not contain the selected Developer ID certificate."
    exit 1
fi

if [[ -z "$SPARKLE_PRIVATE_KEY_PATH" ]]; then
    echo "❌ FENCE_SPARKLE_PRIVATE_KEY_PATH is required for a complete release."
    exit 1
fi
if [[ "$SPARKLE_PRIVATE_KEY_PATH" != /* || ! -f "$SPARKLE_PRIVATE_KEY_PATH" || -L "$SPARKLE_PRIVATE_KEY_PATH" ]]; then
    echo "❌ Sparkle private key must be an absolute, regular, non-symlink file."
    exit 1
fi
if [[ "$(/usr/bin/stat -f '%Lp' "$SPARKLE_PRIVATE_KEY_PATH")" != "600" ||
      "$(/usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$SPARKLE_PRIVATE_KEY_PATH")")" != "700" ]]; then
    echo "❌ Sparkle private key must be mode 600 inside a mode-700 directory."
    exit 1
fi
if [[ ! -x "$PROJECT_DIR/Sparkle/bin/sign_update" ]]; then
    echo "❌ Sparkle sign_update tool is missing or not executable."
    exit 1
fi
configured_sparkle_public_key="$(/usr/bin/xcrun swift \
    "$PROJECT_DIR/scripts/sparkle-public-key.swift" "$SPARKLE_PRIVATE_KEY_PATH")"
app_sparkle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
    "$PROJECT_DIR/Info.plist" 2>/dev/null || true)"
if [[ -z "$app_sparkle_public_key" ||
      "$configured_sparkle_public_key" != "$app_sparkle_public_key" ]]; then
    echo "❌ Sparkle private key does not match Info.plist:SUPublicEDKey."
    exit 1
fi

if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    if [[ "$SIGNING_KEYCHAIN" != /* ]]; then
        echo "❌ FENCE_RELEASE_KEYCHAIN_PATH must be an absolute path."
        exit 1
    fi

    if [[ ! -f "$SIGNING_KEYCHAIN" || -L "$SIGNING_KEYCHAIN" ]]; then
        echo "❌ Signing keychain not found: $SIGNING_KEYCHAIN"
        exit 1
    fi
    if [[ "$(/usr/bin/stat -f '%Lp' "$SIGNING_KEYCHAIN")" != "600" ||
          "$(/usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$SIGNING_KEYCHAIN")")" != "700" ]]; then
        echo "❌ Signing keychain must be mode 600 inside a mode-700 directory."
        exit 1
    fi

    if ! /usr/bin/security list-keychains -d user | \
        /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' | \
        /usr/bin/grep -Fqx "$SIGNING_KEYCHAIN"; then
        echo "❌ The signing keychain must be on the user Keychain search list for codesign."
        echo "   Keep it locked at rest; this script still selects it explicitly with --keychain."
        exit 1
    fi

    if [[ -n "$SIGNING_KEYCHAIN_PASSWORD_FILE" ]]; then
        if [[ "$SIGNING_KEYCHAIN_PASSWORD_FILE" != /* ]]; then
            echo "❌ FENCE_RELEASE_KEYCHAIN_PASSWORD_FILE must be an absolute path."
            exit 1
        fi
        if [[ ! -f "$SIGNING_KEYCHAIN_PASSWORD_FILE" || -L "$SIGNING_KEYCHAIN_PASSWORD_FILE" ]]; then
            echo "❌ Signing keychain password file not found."
            exit 1
        fi
        if [[ "$(/usr/bin/stat -f '%Lp' "$SIGNING_KEYCHAIN_PASSWORD_FILE")" != "600" ||
              "$(/usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$SIGNING_KEYCHAIN_PASSWORD_FILE")")" != "700" ]]; then
            echo "❌ Signing keychain password file must be mode 600 inside a mode-700 directory."
            exit 1
        fi

    fi

    CODESIGN_KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
    signing_identities="$(/usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN")"
    identity_matches="$(printf '%s\n' "$signing_identities" | \
        /usr/bin/awk -v expected="$DEVELOPER_ID_SHA1" '$2 == expected { count += 1 } END { print count + 0 }')"
    if [[ "$identity_matches" -ne 1 ]]; then
        echo "❌ Developer ID identity is not available in the configured signing keychain."
        unset signing_identities
        exit 1
    fi
    unset signing_identities
elif [[ -n "$SIGNING_KEYCHAIN_PASSWORD_FILE" ]]; then
    echo "❌ FENCE_RELEASE_KEYCHAIN_PATH is required when a keychain password file is configured."
    exit 1
fi

if [[ -z "$SIGNING_KEYCHAIN" ]]; then
    signing_identities="$(/usr/bin/security find-identity -v -p codesigning)"
    identity_matches="$(printf '%s\n' "$signing_identities" | \
        /usr/bin/awk -v expected="$DEVELOPER_ID_SHA1" '$2 == expected { count += 1 } END { print count + 0 }')"
    if [[ "$identity_matches" -ne 1 ]]; then
        echo "❌ Developer ID identity is not available in the default keychain search list."
        exit 1
    fi
    unset signing_identities
fi

case "${FENCE_DMG_HEADLESS:-0}" in
    0) ;;
    1) CREATE_DMG_ARGS=(--skip-jenkins) ;;
    *)
        echo "❌ FENCE_DMG_HEADLESS must be 0 or 1."
        exit 1
        ;;
esac

codesign_release() {
    /usr/bin/codesign "${CODESIGN_KEYCHAIN_ARGS[@]}" "$@"
}

if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
        echo "❌ ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be configured together."
        exit 1
    fi
    if [[ "$ASC_KEY_PATH" != /* || ! -f "$ASC_KEY_PATH" || -L "$ASC_KEY_PATH" ]]; then
        echo "❌ ASC_KEY_PATH must be an absolute, regular, non-symlink file."
        exit 1
    fi
    if [[ "$(/usr/bin/stat -f '%Lp' "$ASC_KEY_PATH")" != "600" ||
          "$(/usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$ASC_KEY_PATH")")" != "700" ]]; then
        echo "❌ App Store Connect private key must be mode 600 inside a mode-700 directory."
        exit 1
    fi
    NOTARY_AUTH_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
    if [[ "${FENCE_DMG_HEADLESS:-0}" -eq 1 ]]; then
        echo "❌ App Store Connect API-key authentication is required for a headless release."
        exit 1
    fi
    NOTARY_AUTH_ARGS=(--keychain-profile "AC_PASSWORD")
fi

# Prove private-key access without modifying the existing Sparkle executable,
# then keep the Keychain locked while build phases and external tools run.
unlock_signing_keychain
codesign_release --dryrun --force --timestamp=none --sign "$DEVELOPER_ID" \
    "$PROJECT_DIR/Sparkle/bin/sign_update"
lock_signing_keychain

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
    MARKETING_VERSION="$VERSION" \
    SENTRY_DSN="${SENTRY_DSN:-}" \
    clean build | tail -20

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi
echo "✓ Build complete"

# A configured production Sentry build is not releasable without its matching
# debug symbols. The DSN is public app configuration; the auth token remains
# release-environment-only and is never copied into Fence.app.
if [[ -n "${SENTRY_DSN:-}" ]]; then
    : "${SENTRY_AUTH_TOKEN:?SENTRY_AUTH_TOKEN is required when SENTRY_DSN is configured}"
    : "${SENTRY_ORG:?SENTRY_ORG is required when SENTRY_DSN is configured}"
    : "${SENTRY_PROJECT:?SENTRY_PROJECT is required when SENTRY_DSN is configured}"

    if ! command -v sentry-cli >/dev/null 2>&1; then
        echo "❌ sentry-cli is required when SENTRY_DSN is configured"
        exit 1
    fi

    DSYM_PATH="$BUILD_DIR/Fence.app.dSYM"
    if [[ ! -d "$DSYM_PATH" ]]; then
        echo "❌ Sentry dSYM missing at $DSYM_PATH"
        exit 1
    fi

    echo "→ Uploading Sentry debug symbols..."
    sentry-cli debug-files upload \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        "$DSYM_PATH"
    echo "✓ Sentry debug symbols uploaded"
else
    echo "→ Sentry disabled for this build (SENTRY_DSN is empty)"
fi

echo "→ Embedding Direct Distribution provisioning profile..."
cp "$PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"

# Sign all components with hardened runtime
echo "→ Signing app components..."
unlock_signing_keychain

# Sign Sparkle framework internals first (deepest first)
while IFS= read -r -d '' binary; do
    echo "  Signing: $binary"
    codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp "$binary"
done < <(find "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
    -type f \( -name "*.app" -o -perm +111 \) -print0)

# Sign Sparkle Autoupdate.app bundle
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app" ]; then
    echo "  Signing: Autoupdate.app"
    codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app"
fi

# Sign Sparkle framework
echo "  Signing: Sparkle.framework"
codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Sign the privileged helper/daemon
if [ -f "$APP_PATH/Contents/Library/LaunchServices/org.eyebeam.selfcontrold" ]; then
    echo "  Signing: org.eyebeam.selfcontrold"
    codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
        "$APP_PATH/Contents/Library/LaunchServices/org.eyebeam.selfcontrold"
fi

# Sign helper executables in MacOS
for helper in "$APP_PATH/Contents/MacOS/"*; do
    if [ -f "$helper" ] && [ -x "$helper" ]; then
        echo "  Signing: $(basename "$helper")"
        codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp "$helper"
    fi
done

# Finally sign the main app bundle
echo "  Signing: Fence.app"
codesign_release --force --sign "$DEVELOPER_ID" --options runtime,library,hard,kill --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

# Verify signature
echo "→ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
lock_signing_keychain
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
    "${NOTARY_AUTH_ARGS[@]}" \
    --wait

# Staple the ticket
echo "→ Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
echo "✓ Notarization complete"

# Create DMG
echo "→ Creating DMG..."
rm -f "$OUTPUT_DIR/$DMG_NAME"
create-dmg "${CREATE_DMG_ARGS[@]}" \
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
unlock_signing_keychain
codesign_release --sign "$DEVELOPER_ID" "$OUTPUT_DIR/$DMG_NAME"
lock_signing_keychain
echo "✓ DMG signed"

# Notarize the DMG too
echo "→ Notarizing DMG..."
xcrun notarytool submit "$OUTPUT_DIR/$DMG_NAME" \
    "${NOTARY_AUTH_ARGS[@]}" \
    --wait

xcrun stapler staple "$OUTPUT_DIR/$DMG_NAME"
echo "✓ DMG notarized"

# Final ZIP (for Sparkle updates)
echo "→ Creating final ZIP for Sparkle..."
cd "$BUILD_DIR"
rm -f "$OUTPUT_DIR/$ZIP_NAME"
ditto -c -k --keepParent "Fence.app" "$OUTPUT_DIR/$ZIP_NAME"

# Generate the final ZIP's Sparkle signature without consulting a login Keychain.
echo "→ Signing Sparkle update..."
sparkle_signature_output="$("$PROJECT_DIR/Sparkle/bin/sign_update" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    "$OUTPUT_DIR/$ZIP_NAME")"
if [[ "$sparkle_signature_output" != *"sparkle:edSignature="* ||
      "$sparkle_signature_output" != *"length="* ]]; then
    echo "❌ Sparkle signature output was incomplete."
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "DMG: $OUTPUT_DIR/$DMG_NAME"
echo "ZIP: $OUTPUT_DIR/$ZIP_NAME"
echo ""
echo "Sparkle appcast attributes:"
printf '%s\n' "$sparkle_signature_output"
