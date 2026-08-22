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
5. Location denial, an unavailable or simulated fix, reverse-geocoding failure,
   transport failure, or persistence failure leaves the last root-accepted
   timezone unchanged. Fence never falls back to IP geolocation or to a newly
   changed system timezone during an active commitment.
6. Fence does not persist, log, upload, or send coordinates over its XPC
   boundary. Apple Location Services and reverse geocoding remain platform
   services outside Fence's storage and telemetry.
7. Existing recurring commitments are pinned once, at helper upgrade, to the
   then-current timezone with automatic travel off.

The absolute system clock is assumed to remain correct. This decision protects
the local-wall-time interpretation of the recurring week, Protected Hours,
calendar-day commitment extensions, and daily break-credit rollover.

## Implementation boundary

- Core Location runs only in the logged-in Fence app. The root daemon receives
  no coordinates and requests no Location Services permission.
- A new automatic commitment accepts only a fresh timezone resolved in the
  current app session; writable app preferences are never a commit authority.
- Automatic timezone mutations require the exact root commitment identity,
  owner, generation, an enabled location-following mode, and a valid named
  timezone.
- The change is an additive extension of the recurring schema so older helpers
  can continue reading the root settings during rollback.
- No coordinate history, offline timezone database, IP lookup, continuous
  location telemetry, or speculative attestation layer is introduced.

## Consequences

- Changing Time Zone in System Settings no longer moves an active recurring
  schedule.
- A normal VPN cannot substitute its exit region because Fence does not use IP
  geolocation. A VPN may make lookup unavailable, in which case the previous
  accepted timezone remains authoritative.
- Automatic travel is convenience against ordinary configuration changes, not
  cryptographic proof of physical presence against an administrator modifying
  Fence or macOS.

## Rollback

Older helpers ignore the additive timezone fields and retain their previous
local-time behavior. Do not remove the legacy-field acceptance path until the
rollback window for the recurring scheduler has closed.
