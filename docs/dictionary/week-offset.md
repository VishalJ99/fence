# Week Offset

<!-- KEYWORDS: week, offset, current, next, navigation, weekOffset, future -->

**Also known as:** Week Index, Week Navigation

---

## Brief Definition

An index for week navigation: 0 = current week, 1 = next week, etc.

---

## Detailed Definition

Week Offset is used throughout the scheduling system to reference different weeks relative to today:

| Offset | Meaning |
|--------|---------|
| 0 | Current week (Monday through Sunday containing today) |
| 1 | Next week |
| 2 | Week after next |
| -1 | Previous week (read-only, for history) |

This allows users to plan future weeks before committing, and the system to
calculate the absolute dates and local week scope for a root-owned owner/week
batch. Root admission ultimately compares the authenticated owner and absolute
week bounds, so a timezone-derived key shift cannot bypass an unexpired
commitment envelope.

---

## Context/Trigger

- Week navigation arrows in `SCWeekScheduleWindowController`
- Parameter to most scheduling methods
- Used to calculate absolute dates from day-of-week

---

## Code Locations

| File | Purpose |
|------|---------|
| `SCWeekScheduleWindowController.m` | `editingWeekOffset` property, navigation |
| `Block Management/SCScheduleManager.m` | `commitToWeekWithOffset:completion:` |
| `Block Management/SCScheduleLaunchdBridge.m` | `blockWindowsForSchedule:day:weekOffset:` |
| `Block Management/SCWeeklySchedule.m` | `weekKeyForDate:`, week calculation helpers |

---

## Week Key Calculation

```objc
// Convert week offset to storage key
+ (NSString *)weekKeyForDate:(NSDate *)date;
// Returns "YYYY-MM-DD" for the Monday of that week

// Example:
// Today is Wednesday Dec 25, 2024
// Week offset 0 → "2024-12-23" (Monday of this week)
// Week offset 1 → "2024-12-30" (Monday of next week)
```

---

## Related Terms

- [Committed State](committed-state.md) - Commitment is per-week (by offset)
- [Block Window](block-window.md) - Uses offset to compute absolute dates
- [Segment](segment.md) - Created for a specific week offset

---

## Anti-definitions (What this is NOT)

- **NOT** a date - it's a relative index
- **NOT** a day offset - it's a WEEK offset (7-day jumps)
- **NOT** used for intra-week navigation - that's day-of-week (SCDayOfWeek)

---

## UI Navigation

```
  ◀ Previous Week    [Week of Dec 23, 2024]    Next Week ▶
        (-1)               (offset 0)              (+1)

When viewing future week:
  ◀ Previous Week    [Week of Dec 30, 2024]    Next Week ▶
        (0)                (offset 1)              (+2)
```

---

## Usage Pattern

```objc
// Commit next week's schedule
[scheduleManager commitScheduleForWeekOffset:1];

// Get schedules for current week
NSArray *schedules = [scheduleManager schedulesForWeekOffset:0];

// Check if next week is committed
BOOL committed = [scheduleManager isCommittedForWeekOffset:1];

// Calculate block windows for next week's Monday
NSArray *windows = [bridge blockWindowsForSchedule:schedule
                                               day:SCDayOfWeekMonday
                                        weekOffset:1];
```
