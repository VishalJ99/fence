# PER-444: Travel timezone contract

## Decision

Recurring commitments use a root-owned timezone rather than the mutable macOS
system timezone.

1. Every new recurring commitment records a named timezone identifier and
   whether it follows location-derived timezone changes.
2. Travel mode is chosen before Commit and is immutable until explicit End.
3. With automatic travel off, Fence snapshots the Mac timezone at Commit and
   ignores later system-timezone changes. Travelers must plan ahead and shift
   their drawn blocks for the destination timing before committing.
4. With automatic travel on, the Fence app requests approximate Location
   Services access, resolves a transient coordinate to a named timezone, and
   sends only that timezone identifier to `selfcontrold`.
5. Fence requests one location at Commit, app startup, wake from sleep, and
   explicit opening of the weekly schedule UI. It does not continuously track
   location and does not poll Location Services on a timer.
6. A fresh accepted result is preferred for a new automatic commitment. If a
   one-shot request instead fails transiently because no usable fix, network,
   or reverse-geocoding result is available, Commit may use the last timezone
   previously persisted by the root helper for that user, regardless of age.
   If there is no such timezone, Commit is refused.
7. Location Services disabled, undetermined, denied, or restricted never uses
   the stored fallback for a new commitment. The user must enable access or
   turn automatic travel off. An in-flight request must finish rather than
   falling back early.
8. Fence does not persist, log, upload, or send coordinates over its XPC
   boundary. Apple Location Services and reverse geocoding remain platform
   services outside Fence's storage and telemetry.
9. Existing recurring commitments are pinned once, at helper upgrade, to the
   then-current timezone with automatic travel off.

The absolute system clock is assumed to remain correct. This decision protects
the local-wall-time interpretation of the recurring week, Protected Hours,
calendar-day commitment extensions, and daily break-credit rollover.

## Implementation boundary

- Core Location runs only in the logged-in Fence app. The root daemon receives
  no coordinates and requests no Location Services permission.
- The helper stores one last location-resolved timezone identifier and
  daemon-stamped date per authenticated UID. It stores no coordinates. A new
  automatic commitment accepts either a fresh current-session result or that
  root-owned value after a transient resolution failure; writable app
  preferences are never a commit authority. The stored date is informational
  only and is never used as a freshness or eligibility cutoff.
- Automatic timezone mutations require the exact root commitment identity,
  owner, generation, an enabled location-following mode, and a valid named
  timezone.
- The trusted fallback is a separate additive top-level root-settings cache.
  Protocol v8 advertises it explicitly; older helpers ignore and preserve the
  unknown key while continuing to read existing recurring commitments.
- No coordinate history, offline timezone database, IP lookup, continuous
  location monitoring, timer-based location polling, or speculative
  attestation layer is introduced.

## Consequences

- Changing Time Zone in System Settings no longer moves an active recurring
  schedule.
- A normal VPN cannot substitute its exit region because Fence does not use IP
  geolocation. A VPN may make lookup unavailable; a new Commit may then use the
  last root-trusted timezone, while an active commitment keeps its existing
  root-owned timezone.
- If a Mac crosses a timezone while staying awake and the weekly UI remains
  closed, Fence keeps the previous root timezone until the next approved
  one-shot trigger.
- If the daemon must defer a freshly resolved timezone until an active block
  ends, the app keeps that accepted identifier only in memory and retries on
  the existing block-teardown event. It does not request location again or run
  a retry timer.
- Automatic travel is convenience against ordinary configuration changes, not
  cryptographic proof of physical presence against an administrator modifying
  Fence or macOS.

## Rollback

A v7 helper continues enforcing existing commitments with their root-owned
timezone fields, but it cannot read or write the offline fallback cache. The
current app therefore requires the v8 capability before new recurring
operations. App and helper must be rolled back together if v8 is removed.
