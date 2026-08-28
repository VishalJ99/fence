# PER-444: Recurring schedule, breaks, Protected Hours, and emergency exit

## Decision

Fence for macOS adopts the following Fence iOS product contract:

1. The editable schedule is one recurring seven-day template rather than separate current- and next-week schedules.
2. A commitment starts with a one-to-seven-day lock. When that deadline expires, recurring enforcement continues until the user explicitly ends the commitment. While the commitment remains active, the user may extend its lock deadline by one to seven days, up to a maximum remaining lock horizon of 14 days.
3. Regular breaks cost one daily break credit and last 5, 15, or 30 minutes. Ending a break early does not refund the credit.
4. Protected Hours are a recurring local-wall-time interval. They prevent new breaks, temporarily override an active break, and prevent the free ending of an expired commitment.
5. While a recurring commitment survives, Protection settings may only become stricter: the daily break allowance may decrease, the emergency-unlock wait may increase, and Protected Hours may be enabled or expanded. The reverse changes become editable only after explicit End. Legacy finite commitments retain their existing full lock.
6. Protected Hours expansion means that every previously protected local wall-clock minute remains protected. This set-inclusion rule applies equally to same-day and overnight ranges and is enforced against the current root-owned commitment before mutation.
7. The first migration retains the existing macOS allow-window bundle semantics and read-only committed calendar. Block-window bundles, IDK breaks, and Live Activity equivalents are follow-up work.

## Emergency exit

Emergency exit remains available behind a continuous-attention flow:

1. The wait duration is user-configurable in Protection settings and defaults to 180 seconds. Each attempt must remain full screen, foreground, and focused for the entire configured duration.
2. Each attempt samples exactly one checkpoint from a duration-relative normal distribution. The existing 180-second setting retains its mean of 90 seconds, standard deviation of 30 seconds, and clamp interval from 45 through 177 seconds.
3. At the checkpoint, the interface greys and requires one explicit confirmation click within three seconds.
4. Missing that confirmation, deactivating Fence, losing the emergency window as the key window, or leaving full screen resets the attempt to the configured duration and samples a new checkpoint.
5. Completing the uninterrupted attempt unlocks the existing emergency-exit action. Emergency Unlock has no credit balance or usage limit; regular break credits remain separate.

## Implementation boundary

The migration extends the existing daemon scheduler only where behavior must remain correct while the app is closed, asleep, rebooted, or crossing a schedule, break, or Protected Hours boundary. Ordinary settings and break-credit accounting remain app-managed unless implementation evidence demonstrates a correctness problem. This work does not introduce a broader anti-tamper redesign.

## Migration

Existing live V1 and V2 absolute commitments are not rewritten. Identical legacy current/next drafts may collapse automatically; a conflict requires an explicit user choice. Legacy keys remain available during the rollback window.

## Consequences

- The calendar and commitment state become recurring rather than week-expiring.
- The commitment deadline controls End eligibility, not recurrence, and may be extended while the commitment remains active.
- A timed break pauses only schedule-owned enforcement; manual and test blocks remain untouched.
- An unexpired break can resume after Protected Hours finish, matching Fence iOS.
- Emergency exit requires continuous foreground attention but remains recoverable without permanently weakening the commitment.
- Protection settings can only become stricter for the entire active recurring commitment, including after its End-eligibility deadline.

## Rollback

Disable creation of the recurring commitment schema and continue draining existing root-owned recurring sessions with the matching daemon. Preserve legacy current/next data until the recurring migration has been validated and the rollback window has closed.
