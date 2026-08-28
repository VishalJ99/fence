# PER-444: macOS countdown warning surface

## Status

Approved by the user during product review on 2026-08-27.

## Context

Fence must warn before a recurring schedule starts blocking and before a timed
break ends. The warning needs a visible 90-second ring without bringing Fence
to the foreground. Native ActivityKit APIs cannot be originated by a macOS app,
so the iOS Live Activity surface is not available locally on macOS.

## Decision

- Use one app-owned, non-activating AppKit panel centred below the menu bar on
  the screen containing Fence's status item.
- Show it during the final 90 seconds before either event.
- Use only the copy `Break ending soon` or
  `<Bundle name(s)> blocking starting soon`; the ring is the countdown and no
  clock time or numeric countdown is shown.
- When a new exact warning event first appears, play the built-in macOS `Ping`
  sound once. Timer refreshes and recalculations for the same event must not
  replay it.
- Use the reviewed Strong entrance treatment: a short 12-point slide and
  0.96-to-1 scale, two ring pulses, two subtle red full-pill highlights, and a
  brief red border accent, then leave the surface static. With Reduce Motion
  enabled, use no slide, scale, ring pulse, or border animation and show one
  non-moving highlight instead.
- Reveal an `x` dismiss control on hover. Dismissal is scoped to the exact event
  and never changes the break, schedule, or enforcement state.
- Derive scheduled block starts from the recurring commitment's named timezone
  and the same half-open compiled weekly policy, timed-break override, and
  Protected Hours precedence used by enforcement. Warn only when the effective
  blocklist gains at least one entry, so a handoff between bundles that contain
  the same entries does not produce a false warning.
- Keep this an app-level convenience. It is available while Fence is running;
  guaranteeing the surface after Fence is force-quit would require a separate
  background UI agent and is outside this change.

## Consequences

- Break-end and block-start warnings share one visual implementation while
  retaining separate event identities.
- Wake, schedule changes, commitment timezone changes, and system clock changes
  recalculate the absolute target instead of decrementing a stored counter.
- The panel can appear over other apps without activating Fence.
