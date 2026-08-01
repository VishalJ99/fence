# PER-414: Tab binary and permission boundary

## Status

Pending maintainer review.

## Context

The first accountability-companion milestone needs a tiny notch-adjacent pair of eyes. Later milestones may add ScreenCaptureKit, microphone, network, Accessibility, or Automation access. Adding those permissions to Fence would expand the blocker application's trust surface and couple experimental grants to the production app.

## Decision

1. Build the companion as a standalone macOS application named `Tab`, in its own `Tab/Tab.xcodeproj`, rather than as a Fence target or process.
2. Use the explicit bundle identifier `app.usefence.tab`. Keep this identifier stable if the temporary display name changes so future TCC permission history remains attached to one companion identity.
3. Give Tab its own sandbox and entitlements file. Milestone one enables only the App Sandbox and declares no Screen Recording, microphone, Accessibility, Automation, keychain-group, network, Sparkle, daemon, or privileged-helper access.
4. Keep Tab independent of Fence's CocoaPods workspace, helper protocols, blocking state, signing configuration, and launch-at-login behavior.
5. Target macOS 12.0 for the eyes milestone. Future ScreenCaptureKit work must be availability-gated from macOS 12.3 or explicitly raise the deployment target in a separately reviewed decision.
6. Use chibi concern cues rather than punitive alarm cues: high-contrast raised-inner brows for mild concern; the same grey brows rotating inner-down, smaller pupils, a brief wiggle, and a bold saturated-red four-lobed stress-vein mark with a black separation stroke for very concerned. The mark may overlap the right eye slightly, and the very-concerned right brow may shorten to reserve space, so the symbol remains legible without increasing the 44 x 20-point panel. Red is reserved for the high-heat accent rather than the brows. A persistent exclamation mark is excluded because it reads as a system alert. The default launch remains neutral.
7. During PER-414 UI tuning only, clicking the 44 x 20-point face cycles neutral, mild concern, and very concerned. The window remains non-activating, but this small region is not click-through. Revisit click-through behavior when expression control is connected to the accountability state machine.

## Consequences

- Fence's permissions and operational surface do not change.
- Tab can be built, tested, signed, launched, renamed, and eventually distributed independently.
- A separate Xcode project adds a small amount of project metadata but avoids hand-packaging an executable and supports future privacy manifests, entitlements, archives, and notarization.
- Signing identity still matters to durable TCC recognition; local ad-hoc builds are suitable for the permission-free milestone but a stable development/distribution signature is required before permission persistence is evaluated.

## Rollback

Delete the self-contained `Tab/` project and its `DATA.md` entry. No Fence project, workspace, daemon, entitlement, or source target needs to be unwound.
