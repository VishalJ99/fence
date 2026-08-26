# PER-444: macOS countdown warning surface

## Status

Pending human review.

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
