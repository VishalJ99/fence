# PER-444: Recurring schedule, breaks, Protected Hours, and emergency exit

## Decision

Fence for macOS adopts the following Fence iOS product contract:

1. The editable schedule is one recurring seven-day template rather than separate current- and next-week schedules.
2. A commitment locks editing for one to seven days. When that deadline expires, recurring enforcement continues until the user explicitly ends the commitment.
3. Regular breaks cost one daily break credit and last 5, 15, or 30 minutes. Ending a break early does not refund the credit.
4. Protected Hours are a recurring local-wall-time interval. They prevent new breaks, temporarily override an active break, and prevent the free ending of an expired commitment.
5. The first migration retains the existing macOS allow-window bundle semantics and read-only committed calendar. Block-window bundles, strength-only active editing, IDK breaks, and Live Activity equivalents are follow-up work.

## Emergency exit

Emergency exit remains available behind a continuous-attention flow:

1. Each attempt lasts 180 seconds and must remain full screen, foreground, and focused for the entire attempt.
2. Each attempt samples exactly one checkpoint from a normal distribution with mean 90 seconds and standard deviation 30 seconds, clamped to the interval from 45 through 177 seconds.
3. At the checkpoint, the interface greys and requires one explicit confirmation click within three seconds.
4. Missing that confirmation, deactivating Fence, losing the emergency window as the key window, or leaving full screen resets the attempt to 180 seconds and samples a new checkpoint.
5. Completing the uninterrupted attempt unlocks the existing emergency-exit action. Break credits and emergency-exit credits remain separate concepts.

## Implementation boundary

The migration extends the existing daemon scheduler only where behavior must remain correct while the app is closed, asleep, rebooted, or crossing a schedule, break, or Protected Hours boundary. Ordinary settings and break-credit accounting remain app-managed unless implementation evidence demonstrates a correctness problem. This work does not introduce a broader anti-tamper redesign.

## Migration

Existing live V1 and V2 absolute commitments are not rewritten. Identical legacy current/next drafts may collapse automatically; a conflict requires an explicit user choice. Legacy keys remain available during the rollback window.

## Consequences

- The calendar and commitment state become recurring rather than week-expiring.
- A timed break pauses only schedule-owned enforcement; manual and test blocks remain untouched.
- An unexpired break can resume after Protected Hours finish, matching Fence iOS.
- Emergency exit requires continuous foreground attention but remains recoverable without permanently weakening the commitment.

## Rollback

Disable creation of the recurring commitment schema and continue draining existing root-owned recurring sessions with the matching daemon. Preserve legacy current/next data until the recurring migration has been validated and the rollback window has closed.
