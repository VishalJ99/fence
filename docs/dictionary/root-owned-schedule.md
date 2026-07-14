# Root-Owned Schedule

<!-- KEYWORDS: root scheduler, root-owned schedule, scheduler v2, ApprovedSchedules, commitment batch, selfcontrold -->

**Also known as:** V2 Schedule Record, Scheduler V2 Record, Root-Scheduler Segment

---

## Brief Definition

An immutable root `ApprovedScheduleCommitments` absolute-week envelope plus
zero or more committed [Segment](segment.md) records in `ApprovedSchedules`,
reconciled directly by `selfcontrold` without a per-segment user LaunchAgent.

---

## Detailed Definition

At commit time, Fence sends one absolute-week envelope plus every non-expired
segment for one owner in a single authenticated XPC request. A week with no
blocking segments still has an envelope. The daemon validates the complete
batch and absolute overlap before mutation:

- an exact existing batch with matching commitment+generation and records is an idempotent retry;
- a different batch is rejected if its absolute week overlaps an unexpired
  envelope or schedule record (including V1) for that owner, even when its
  local `weekKey` differs;
- legacy V1 registration is reciprocally rejected when its absolute window
  overlaps an unexpired V2 envelope;
- otherwise the daemon atomically stores the immutable envelope in
  `ApprovedScheduleCommitments` and zero or more segment records in
  `ApprovedSchedules`.

It persists once, verifies the envelope and every validated record field in
SCSettings' post-sync view, and asks its serialized scheduler to reconcile
wall-clock state. This check is not an independent raw-disk reread.

The commitment envelope contains owner, absolute week bounds, local week key,
commitment ID, generation, and creation metadata. Each V2 segment record
contains:

- a schema version and segment UUID;
- the authenticated controlling UID and local week key;
- commitment, generation, and policy-revision UUIDs;
- absolute half-open start/end dates (`start <= now < end`);
- source bundle UUIDs, the merged blocklist, and block settings.

The IDs, UID, dates, bundle membership, entries, and policy revision stay
local. Remote diagnostics use only typed enums, booleans, bounded counts, and
error codes.

---

## Scheduling Authority

`SCDaemonScheduler` recomputes desired enforcement from the root store at:

1. daemon startup;
2. the next absolute start/end boundary;
3. wake;
4. wall-clock or timezone change;
5. a schedule-store mutation;
6. active-block completion; and
7. a 60-second periodic backstop.

The exact wall-clock timer improves promptness. Re-reading the persisted store
is the correctness mechanism after sleep, reboot, a missed timer, or clock
change.

Before a reconciliation is treated as already correct, active state must match
schedule/owner provenance, mode, and content. V2 also matches commitment,
generation, and policy revision. A denylist may contain additional strictified
entries but may not be weaker than the stored record.

---

## Arbitration

- Manual and safety-test blocks are never replaced by the scheduler.
- If a V2 mutation would require replacing one active policy with another,
  reconciliation defers. Fence does not remove the current PF/hosts/AppBlocker
  rules before the replacement is staged.
- The existing one-minute compatibility gap between adjacent computed
  segments remains part of this cutover. Removing it requires a separately
  verified active-to-active replacement primitive.

When strictify adds entries to the root record that currently owns the active
block, the daemon holds its mutation lock while it physically appends and
verifies hosts/PF/app enforcement. Only then does it persist the stricter root
record. Exact-union retries still reapply the physical layers.

---

## Removal Boundary

An unexpired V2 record cannot be removed through the legacy unregister path.
Release builds also reject bulk approved-schedule clearing. DEBUG builds keep
that operation for tests, but clear `ApprovedSchedules` and
`ApprovedScheduleCommitments` together so no orphaned commitment authority is
left behind.

---

## Code Locations

| File | Purpose |
|------|---------|
| `Block Management/SCScheduleManager.m` | Compiles a week into the authenticated V2 batch and stores the local manifest |
| `Common/SCXPCClient.m` | Protocol/capability gate and batch XPC client |
| `Daemon/SCDaemonXPC.m` | Validates overlap/idempotency and atomically persists the immutable envelope + records |
| `Daemon/SCDaemonScheduler.m` | Selects the desired record, owns timers, and serializes reconciliation |
| `Daemon/SCDaemonBlockMethods.m` | Applies/ends schedule-owned blocks and records local provenance |
| `Common/SCSettings.m` | Validates the root store and active provenance fields |

---

## Related Terms

- [Segment](segment.md) - the computed time slice stored by the V2 record
- [Pre-Authorized Schedule](pre-authorized-schedule.md) - umbrella term; its
  V1 LaunchAgent form is now compatibility-only
- [Committed State](committed-state.md) - the UI lock created after verified
  root-store persistence
- [Merged Blocklist](merged-blocklist.md) - the entries applied for a segment

---

## Anti-definitions (What this is NOT)

- **NOT** a per-segment LaunchAgent or CLI invocation
- **NOT** a daemon installation trigger; helper compatibility repair owns
  installation
- **NOT** replaceable or loosenable during its unexpired absolute week; a
  different overlapping batch is rejected, while the exact same
  identity/content is idempotent. Segment blocklists may only grow through
  verified monotonic strictify
- **NOT** absent when the week has no blocking segments; the envelope still
  records the commitment
- **NOT** a promise of gapless active-to-active replacement
- **NOT** an uploaded schedule fingerprint or remote user identifier

---

*Introduced for PER-383 on 2026-07-14.*
