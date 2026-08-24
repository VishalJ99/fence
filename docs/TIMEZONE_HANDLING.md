# Timezone Handling in Fence

Fence has three schedule generations with intentionally different timezone
semantics. Do not infer V3 recurring behavior from the V1/V2 compatibility
paths.

## Behavior by Schedule Generation

| Schedule | Time representation | Timezone behavior |
| --- | --- | --- |
| V1 (rollback/drain only) | Local launchd trigger plus absolute start/end validation | Retains its historical compatibility behavior until the record expires. |
| V2 root-owned week | Absolute `NSDate` segment and commitment bounds | A timezone change cannot move an already committed boundary. |
| V3 recurring commitment | Monday-based local-wall-time template plus a root-owned named timezone | `selfcontrold` evaluates the template, Protected Hours, commitment days, and break-credit days in the commitment's accepted timezone. |

V1 and V2 are bounded schedules. V3 repeats indefinitely until the user
explicitly ends the commitment after its minimum commitment date.

## V3 Recurring Timezone Authority

Every new V3 commitment records, in the root-owned commitment:

- an IANA timezone identifier, such as `Europe/London`; and
- whether the commitment follows location-derived timezone changes.

The mode is chosen before Commit and cannot be changed until the commitment is
ended. Changing Time Zone in macOS System Settings during a commitment does not
change either the stored timezone or the schedule's local-wall-time
interpretation.

The absolute system clock is assumed to remain correct. Fence protects the
timezone used to interpret the recurring week; it does not implement a second
physical clock.

## Travel Modes

### Fixed Timezone

With automatic travel off, Fence snapshots the Mac's named timezone at Commit.
That timezone remains authoritative for the life of the commitment.

If the user expects to travel, the UI tells them to plan ahead and draw the
allow windows for the destination timing before committing. Later changes to
the Mac's system timezone are ignored by the active recurring commitment.

### Follow Location

The user may enable automatic timezone tracking from the **Traveling?** flow
before committing. The logged-in Fence app then:

1. requests one approximate location at Commit, app startup, wake from sleep,
   or explicit opening of the weekly schedule;
2. obtains a transient coordinate;
3. resolves it to a named timezone; and
4. sends only the timezone identifier to `selfcontrold`.

Fence does not keep continuous location updates running and does not poll
Location Services on a timer. If the Mac crosses a timezone while it stays
awake and the weekly UI remains closed, the previous root-owned timezone
remains in use until the next one-shot trigger. If an active block makes a
timezone change temporarily unsafe, Fence retries the already accepted
timezone on the existing block-teardown event without requesting location
again.

Core Location and geocoding remain app-side. Fence does not persist, log,
upload, or send coordinates across XPC. The root daemon does not request
Location Services access, and Fence does not fall back to IP geolocation. A
new automatic commitment requires a fresh result from the current app session;
a saved preference cannot supply its timezone.

## Failure Behavior

The last timezone accepted and persisted by `selfcontrold` remains
authoritative. Fence keeps that timezone when any update fails, including:

- denied or unavailable Location Services;
- an invalid or simulated location fix;
- reverse-geocoding failure;
- app-to-daemon transport failure; or
- root persistence failure.

There is no manual timezone override during an active commitment. An unavailable
location update therefore cannot silently adopt a changed system timezone or
weaken the current schedule.

## Upgrade and Rollback

At helper upgrade, an existing V3 commitment without timezone fields is pinned
once to the then-current named timezone with location following off. The
timezone fields are additive so an older helper can still read the root record
during the rollback window; the older helper retains its previous local-time
behavior.

V1/V2 storage and admission rules are unchanged by the V3 travel feature.

## Source of Truth

The approved product and implementation contract is
[`decisions/human/PER-444-travel-timezone-contract.md`](../decisions/human/PER-444-travel-timezone-contract.md).

*Last updated: August 2026 (PER-444)*
