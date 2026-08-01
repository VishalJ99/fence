# Tab

Tab is a permission-isolated macOS notch companion. The first milestone displays a minimal pair of googly eyes beneath the built-in display's camera housing and follows the global pointer without requesting protected permissions.

## Build and test

```sh
xcodebuild -project Tab/Tab.xcodeproj -scheme Tab \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Tab/Tab.xcodeproj -scheme Tab \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS' test
```

To create a directly launchable local artifact:

```sh
Tab/scripts/build-app.sh
open Tab/dist/Tab.app
```

Tab is an accessory application, so it has no Dock icon. Quit a development build with `pkill -x Tab`.

## Expression previews

Neutral is the default. Static chibi concern states and a development-only cycle can be previewed with launch arguments:

```sh
open -n Tab/dist/Tab.app --args --expression mild
open -n Tab/dist/Tab.app --args --expression very
open -n Tab/dist/Tab.app --args --demo-expressions
```

Mild concern uses straight, high-contrast raised-inner grey brows without an alarm color. Very concerned rotates the same full-length straight brows to inner-down, then adds slightly smaller pupils, a one-shot wiggle, and the familiar coral chibi anger hatch: four separate curves bowing toward an empty center. The four curves are spaced 10 percent farther apart and the complete motif is rotated 20 degrees clockwise. It sits at the top-right temple with roughly one-fifth of its silhouette gently grazing the eye/brow region. The neutral and mild face remains 44 x 20 points; only very concerned adds a 6-point right-side gutter, producing a 50 x 20-point panel. Keeping red out of the brows preserves a caring rather than punitive character. The expression layer does not add permissions.

For the current PER-414 test build, clicking the 44 x 20-point face cycles `neutral -> mild -> very -> neutral`. The panel remains non-activating, but that tiny face area is intentionally not click-through while the expressions are being tuned.

## Permission boundary

Tab uses bundle identifier `app.usefence.tab` and an entitlement file separate from Fence. The eyes milestone does not declare or request Screen Recording, Accessibility, microphone, Automation, or network access.
