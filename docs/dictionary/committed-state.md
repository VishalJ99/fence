# Committed State

<!-- KEYWORDS: committed, commit, locked, finalized, readonly, schedule, week, isCommitted -->

**Also known as:** Locked State, Finalized Schedule

---

## Brief Definition

The state when a user has clicked "Commit to Week" and the schedule is locked - cannot be modified until the week ends.

---

## Detailed Definition

Committed State is entered when a user explicitly confirms their schedule for a given week. Once committed:

1. **Schedule is read-only** - Cannot add, remove, or resize Allowed Windows
2. **Editor is disabled** - Clicking day cells shows an alert instead of opening Editor
3. **Segments are pre-authorized** - Registered with daemon for password-free execution
4. **Anti-cheat protection** - Cannot make schedule "looser" (add more allowed time)
5. **Root envelope is immutable while unexpired** - A different overlapping
   commitment is rejected even if local defaults are missing or travel changes
   the displayed week key
6. **Compatibility and release clears cannot bypass it** - Legacy registration
   rejects an overlapping live V2 envelope, and release builds reject bulk
   approved-schedule clearing

The commitment lasts until `commitmentEndDate` (typically end of Sunday).
The app-local date/manifest drives presentation and mapping, but the root
`ApprovedScheduleCommitments` envelope is the fail-closed admission authority.
Losing the local marker cannot permit a different overlapping commitment.

---

## Context/Trigger

- User clicks "Commit to Week" button in `SCWeekScheduleWindowController`
- Confirmation alert shown with commitment terms
- The app verifies daemon protocol/capability compatibility
- All segments are written as one authenticated owner/week root-store batch
- Committed UI state is persisted only after the daemon verifies the batch

---

## Code Locations

| File | Purpose |
|------|---------|
| `Block Management/SCScheduleManager.h` | `isCommitted` property |
| `Block Management/SCScheduleManager.m` | `commitToWeekWithOffset:completion:` |
| `SCWeekScheduleWindowController.m` | Commit button action, UI restrictions |

---

## Data Model

```objc
// Per-week storage keys
static NSString * const kWeekCommitmentPrefix = @"SCWeekCommitment_";
static NSString * const kWeekScheduleManifestPrefix = @"SCScheduleManifest_";

// SCWeekCommitment_<weekKey> stores the absolute week end NSDate.
// isCommitted is derived by comparing that date with now.

// SCScheduleManifest_<weekKey> stores V2 local mapping metadata:
// schemaVersion, weekKey, commitmentID, generation, week bounds,
// and schedule IDs/bounds/source bundle IDs/policy revisions (no entries).

// Root ApprovedScheduleCommitments stores the authoritative immutable
// owner/absolute-week envelope, including commitments with zero segments.
```

---

## Call Stack

```mermaid
graph TD
    A[User clicks 'Commit to Week'] --> B[Show confirmation alert]
    B --> C{User confirms?}
    C -->|No| D[Abort]
    C -->|Yes| E[commitToWeekWithOffset:completion:]
    E --> F[Calculate segments from all bundles]
    F --> G[Require protocol 5 + root scheduler capabilities]
    G --> H[Send one authenticated owner/week batch]
    H --> I[Daemon rejects overlap or atomically persists immutable envelope + records]
    I --> J[Save local V2 manifest and committed end date]
    J --> K[Set commitmentEndDate = end of Sunday]
    K --> L[Reload UI - Editor disabled]

    style A fill:#e1f5fe
    style L fill:#c8e6c9
```

---

## Related Terms

- [Editor](editor.md) - Cannot open when committed
- [Segment](segment.md) - Created at commit time
- [Pre-Authorized Schedule](pre-authorized-schedule.md) - Registered at commit time
- [Root-Owned Schedule](root-owned-schedule.md) - Current V2 committed segment
- [Week Offset](week-offset.md) - Commitment is per-week
- [Emergency Unlock](emergency-unlock.md) - High-friction escape mechanism

---

## Anti-definitions (What this is NOT)

- **NOT** the same as "saving" - saves are editable, commits are not
- **NOT** auto-triggered - requires explicit user action
- **NOT** reversible before its deadline through ordinary End (the high-friction [Emergency Unlock](emergency-unlock.md) remains available)
- **NOT** a single timestamp - includes start date, end date, and status

---

## UI Behavior When Committed

| Action | Committed Behavior |
|--------|-------------------|
| Click day cell | Alert: "Schedule Locked" |
| Navigate weeks | Can view other weeks normally |
| View current week | Read-only, no editing |
| Start block manually | Still possible (separate from schedule) |
| Emergency Unlock button | Enabled (if credits > 0) - escape hatch |

---

## Confirmation Dialog

```objc
NSAlert *alert = [[NSAlert alloc] init];
alert.messageText = [NSString stringWithFormat:@"Commit to %@?", weekName];
alert.informativeText = [NSString stringWithFormat:
    @"Once committed, the schedule is locked and cannot be modified. "
    @"This commitment lasts until %@.\n\n"
    @"Blocking will start immediately for any in-progress block windows.", lastDay];
[alert addButtonWithTitle:@"Commit"];
[alert addButtonWithTitle:@"Cancel"];
```
