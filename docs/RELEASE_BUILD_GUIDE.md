# Release Build Guide

This document describes how to build, sign, notarize, and distribute Fence.app (formerly SelfControl).

## Prerequisites

1. **Xcode** installed with command-line tools
2. **Developer ID Application identity** plus a matching Direct Distribution profile
3. **App Store Connect API key** for headless notarization, or an interactive saved notarytool profile
4. **CocoaPods** installed (`gem install cocoapods`)
5. **create-dmg** installed (`brew install create-dmg`)
6. **Sparkle Ed25519 private-key file** matching `Info.plist:SUPublicEDKey`

## One-Time Setup

### 1. Install Dependencies

```bash
pod install
```

### 2. Configure release credentials

The release script requires the exact SHA-1 fingerprint of the Developer ID
certificate, an authorized provisioning profile, and the Sparkle private-key
file. Use absolute paths:

```bash
export FENCE_DEVELOPER_ID_SHA1=0123456789ABCDEF0123456789ABCDEF01234567
export FENCE_RELEASE_PROFILE_PATH=/absolute/path/FenceDirectDistribution.provisionprofile
export FENCE_SPARKLE_PRIVATE_KEY_PATH=/absolute/path/sparkle-ed25519.key
```

For an isolated release Keychain, configure its absolute path. A mode-`600`
password file inside a mode-`700` directory enables non-interactive unlock; the
script re-locks the Keychain on exit:

```bash
export FENCE_RELEASE_KEYCHAIN_PATH=/absolute/path/release.keychain-db
export FENCE_RELEASE_KEYCHAIN_PASSWORD_FILE=/absolute/path/release-keychain-password
```

Headless releases also require App Store Connect API-key variables and the
non-GUI DMG mode:

```bash
export ASC_KEY_PATH=/absolute/path/AuthKey_XXXXXXXXXX.p8
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export FENCE_DMG_HEADLESS=1
```

The configured Fence Mac mini keeps these non-secret path selections in
`/Users/dross/.private/fence-release/release.env`. Its release Keychain is on
the user's Keychain search list because `codesign` requires that, but it is not
the default Keychain and remains locked outside release runs. Load the three
private environments without printing them:

```bash
source /Users/dross/.private/appstoreconnect/env
source /Users/dross/.private/fence-release/sentry.env
source /Users/dross/.private/fence-release/release.env
```

No MacBook credential lookup is expected on this configured path. Its isolated
Keychain has passed a headless sign-and-verify after transfer-file cleanup; the
complete post-migration build, notarization, stapling, DMG, and launch sequence
must still be checked on the next authorized release.

## Building a Release

```bash
./scripts/build-release.sh 1.0
```

This script:
1. Validates the exact Developer ID against both the Keychain and profile
2. Validates the Sparkle private key against `Info.plist`
3. Builds the Release configuration using the workspace
4. Signs all nested components with Developer ID + hardened runtime
5. Creates a ZIP and submits it for notarization
6. Staples the app, then creates, signs, notarizes, and staples a DMG
7. Creates the final ZIP and prints its Sparkle signature/appcast attributes
8. Outputs both DMG and ZIP to `dist/`

## Hurdles We Overcame

### Issue 1: Empty MacOS Folder in Release Build

**Symptom:** Release build created an app bundle with empty `Contents/MacOS/` folder.

**Root Cause:** The build was using `-project SelfControl.xcodeproj` instead of `-workspace SelfControl.xcworkspace`. With CocoaPods, you MUST use the workspace so that pod dependencies are built first.

**Fix:** Changed build command to:
```bash
xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl ...
```

### Issue 2: Linker Error - library 'Pods-SCKillerHelper' not found

**Symptom:** `ld: library 'Pods-SCKillerHelper' not found`

**Root Cause:** Same as above - using project instead of workspace meant pod targets weren't being built.

**Fix:** Use `-workspace` instead of `-project`.

### Issue 3: Notarization Credential Error (HTTP 401)

**Symptom:** `HTTP status code: 401. Invalid credentials.`

**Root Cause:** The keychain item `AC_PASSWORD` didn't exist, and we were using the old credential syntax.

**Fix:**
1. Generate app-specific password from appleid.apple.com
2. Store using `xcrun notarytool store-credentials "AC_PASSWORD" ...`
3. Use `--keychain-profile "AC_PASSWORD"` (not `--password "@keychain:..."`)

### Issue 4: Notarization Rejected - Invalid Signatures

**Symptom:** Notarization status "Invalid" with errors about nested binaries not signed with Developer ID.

**Root Cause:** `codesign --deep` doesn't properly sign nested frameworks/helpers for notarization. Each binary needs:
- Developer ID signature (not development certificate)
- Hardened runtime (`--options runtime`)
- Secure timestamp (`--timestamp`)
- No `com.apple.security.get-task-allow` entitlement

**Affected Components:**
- `Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/fileop`
- `Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/Autoupdate`
- `Contents/Library/LaunchServices/org.eyebeam.selfcontrold`

**Fix:** Sign each component individually, from deepest to outermost:
```bash
# Sign Sparkle internals
codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app"

# Sign Sparkle framework
codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Sign daemon
codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$APP_PATH/Contents/Library/LaunchServices/org.eyebeam.selfcontrold"

# Sign main app last
codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$APP_PATH"
```

## Sparkle Updates

The release script signs the final ZIP with
`FENCE_SPARKLE_PRIVATE_KEY_PATH` and prints the `sparkle:edSignature` and
`length` attributes for the appcast. Do not regenerate the ZIP after this step.

## Troubleshooting

### Check Notarization Log

If notarization fails, get the detailed log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "AC_PASSWORD"
```

### Verify Signatures

```bash
codesign --verify --deep --strict --verbose=2 Fence.app
```

### Check Entitlements

```bash
codesign -d --entitlements - Fence.app
```
