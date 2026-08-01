# Fence

<p align="center">
    <img src="./.github/docs/screenshot.png" />
</p>

## About

**Fence** is an open-source macOS application that blocks distracting websites and apps on a weekly schedule. Set your blocking schedule for the entire week, commit to it once, and stick with it—no undos, no exceptions.

Unlike traditional website blockers that let you disable blocking on a whim, Fence enforces your commitment. Once you start a block:
- ✅ **Schedule for the week** - Define when sites/apps are blocked each day
- ✅ **Commit once** - Lock in your schedule after planning
- ✅ **No escape hatches** - Blocks persist even through reboots or app deletion
- ✅ **Block websites AND apps** - Prevent access to both web distractions and desktop apps (Terminal, Cursor, etc.)

## Download

To download the built app, visit [usefence.app](https://usefence.app).

## Credits

Originally forked from [SelfControl](https://selfcontrolapp.com/) by [Charlie Stigler](http://charliestigler.com) and [Steve Lambert](http://visitsteve.com).

Fence was created and is maintained by [Vishal Jain](https://github.com/vishalja1n).

## License

Fence is free software under the GPL. See [this file](./COPYING) for more details.

## Building and Running Fence

> **Want to fork/run without licensing?** See [SETUP.md](./SETUP.md#removing-licensing-logic-for-forks) for instructions on removing the licensing system.

### Prerequisites

- **macOS** (tested on macOS 12+)
- **Xcode** (latest version recommended)
- **Xcode Command Line Tools** - Install with: `xcode-select --install`
- **CocoaPods** - Dependency manager for the project

### Setup Instructions

1. **Clone the repository**
   ```bash
   git clone https://github.com/vishalja1n/fence.git
   cd fence
   ```

2. **Install CocoaPods** (if not already installed)
   ```bash
   sudo gem install cocoapods
   ```

3. **Install dependencies**
   ```bash
   pod install
   ```

4. **Open the workspace**
   ```bash
   open SelfControl.xcworkspace
   ```

   ⚠️ **Important:** Always open `SelfControl.xcworkspace`, **NOT** `SelfControl.xcodeproj`. Opening the project file will cause linker errors.

5. **Build and run**

   **Option A: Using Xcode**
   - Select the "SelfControl" scheme
   - Click the Run button (⌘R)
   - You may need to adjust code signing settings in the project settings

   **Option B: Using Command Line (Debug)**
   ```bash
   xcodebuild -workspace SelfControl.xcworkspace \
              -scheme SelfControl \
              -configuration Debug
   ```

   **Option C: Using Command Line (Release)**
   ```bash
   xcodebuild -workspace SelfControl.xcworkspace \
              -scheme SelfControl \
              -configuration Release \
              -derivedDataPath build/DerivedData \
              -arch arm64
   ```

6. **Run the application**
   ```bash
   open build/Release/SelfControl.app
   ```

   Note: The app requires proper code signing to install the privileged helper tool that performs blocking.

### Building a Release

To create a signed, notarized release with a DMG installer:

```bash
./scripts/build-release.sh 1.0
```

This will create a distributable DMG in the `build/` directory.

### Troubleshooting

**Problem: "library 'Pods-SCKillerHelper' not found"**
- **Solution:** You opened the `.xcodeproj` file instead of `.xcworkspace`. Close Xcode and open `SelfControl.xcworkspace`.

**Problem: Code signing errors**
- **Solution:** In Xcode, go to the project settings → Signing & Capabilities, and either:
  - Sign in with your Apple ID and select your team
  - Or disable "Automatically manage signing" and select a valid certificate

**Problem: Helper tool installation fails**
- **Solution:** This is usually a signing issue. The helper tool requires a valid Developer ID or Ad-Hoc signing to install via `SMJobBless`.

### Project Structure

- `SelfControl.app` - Main application (user interface)
- `selfcontrold` - Privileged daemon that performs blocking (runs as root)
- `SCKillerHelper` - Helper tool for terminating blocked apps
- `Common/` - Shared code between app and daemon
- `Block Management/` - Blocking engine (hosts file, packet filter, app blocker)

### Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## Tab screen-context prototype

`Tab` is a separate experimental macOS binary so its Screen Recording and network permissions do not change Fence's permission surface. Its approved notch eyes remain unchanged; an optional sidecar can prove local screen sensing and model latency.

Build and test it from the repository root:

```bash
xcodebuild -project Tab/Tab.xcodeproj -scheme Tab \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS' test

TAB_SIGNING_MODE=development Tab/scripts/build-app.sh
```

Launch the packaged app with `--screen-context-log` or set `TAB_SCREEN_CONTEXT_LOG=1`. The sidecar is opt-in and behaves as follows:

- ScreenCaptureKit captures locally at no more than one frame per second.
- A 32 x 18 grayscale signature suppresses unchanged frames; Apple Vision OCR runs locally on accepted changes.
- The log displays capture/OCR latency, local CPU, macOS physical footprint, and observed frame rate.
- Remote analysis is off until the user enters an OpenRouter key and enables Luna. The key is kept in process memory only.
- Tab sends bounded app/window metadata and a local OCR excerpt first. It waits one second for context to settle, sends changed text context at most every five seconds, and uses a 30-second unchanged-context heartbeat.
- A low-detail JPEG is encoded and sent only when the metadata response explicitly requests visual context. At most one image is attempted per context fingerprint, with a 30-second global image cooldown.
- OpenRouter requests require structured-output support, prefer the lowest-latency route, deny data-collecting providers, and require zero-data-retention routing. Provider-reported token usage and billed credits are shown in the sidecar; credit-purchase fees are separate.

Screen Recording access is required for local capture. Accessibility, Automation, microphone, and audio permissions are intentionally out of scope for this proof.

## Support This Project

If Fence helps you stay focused, consider [purchasing a license](https://usefence.app) or contributing any amount via [Buy Me a Coffee](https://buymeacoffee.com/vishalja1n) - either one helps keep development going.
