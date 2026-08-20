# Emergency Unlock

<!-- KEYWORDS: emergency, unlock, escape, override, committed, attention, foreground -->

**Also known as:** Emergency Exit, Escape Hatch

## Brief Definition

A high-friction escape from an active commitment. The user must keep Fence full-screen, key, and foreground for the configured wait; a single surprise checkpoint must be confirmed within three seconds or the attempt resets.

## Product Contract

- Available whenever a recurring or surviving legacy commitment is active.
- Has no credit balance or usage limit.
- Wait is configured in Fence > Settings > Protection before committing.
- Default wait is three minutes; supported settings are one through ten minutes.
- At three minutes, the checkpoint follows N(90 seconds, 30 seconds), clamped to 45...177 seconds.
- For other durations, mean and standard deviation scale to one-half and one-sixth of the wait, while the checkpoint remains at least 45 seconds in and at least three seconds before completion.
- Losing foreground, key-window, or full-screen status resets the complete attempt.
- Missing the three-second checkpoint resets the complete attempt.
- Completing the attempt runs the existing verified emergency cleanup and ends the commitment.

## Code Locations

| File | Purpose |
|------|---------|
| `SCEmergencyExitAttempt.m` | Continuous-attention state machine and checkpoint sampling |
| `SCEmergencyExitWindowController.m` | Full-screen attempt UI |
| `SCWeekScheduleWindowController.m` | Entry confirmation and verified cleanup result |
| `Block Management/SCScheduleManager.m` | Configured wait and commitment state |

## Related Terms

- [Committed State](committed-state.md)
- [Break Credits](break-credits.md)

## Anti-definitions

- Not a regular timed break; it ends the commitment.
- Not an instant escape; the uninterrupted foreground wait is mandatory.
- Not credit-limited.
