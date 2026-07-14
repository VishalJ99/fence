# PER-383: Root scheduler authority and legacy rollback

## Status

Pending maintainer review.

## Context

Fence currently stores absolute segment bounds and enforcement policy in the root-owned `ApprovedSchedules` dictionary, but future starts are still duplicated through per-segment user LaunchAgents that execute `selfcontrol-cli`. The daemon also performs startup and one-minute recovery from the same root records. This duplicates execution state across root settings, user plists, launchd's loaded-job graph, and the CLI, and makes strictification and diagnostics depend on all four copies.

The PER-355 telemetry work made the root record the timing authority, added per-user daemon spooling, typed telemetry allowlists, physical postconditions, and a monotonic daemon capability handshake. The scheduler cutover must preserve those boundaries.

## Decisions

1. **`selfcontrold` is the primary timing authority.** Version 2 schedule records contain an authenticated owner, week scope, commitment and generation identifiers, absolute half-open start/end bounds, source bundle membership, a local policy revision, and the complete block policy. The app continues to compile weekly UI state into absolute non-overlapping segments.
2. **Commitment writes are atomic per owner and absolute week.** One authenticated XPC mutation validates the complete batch, persists a separate immutable `ApprovedScheduleCommitments` envelope plus zero or more `ApprovedSchedules` segment records, verifies their complete SCSettings representation, and triggers daemon reconciliation. The envelope exists even for a zero-segment week, so loss of the app-local marker cannot unlock it. Ordinary commitment writes do not reinstall the daemon; the protocol/capability repair path owns helper replacement.
3. **New V2 commitments do not create user LaunchAgents.** Existing V1 approvals and jobs remain supported only as a bounded rollback/drain path. An unexpired V1 record or V2 envelope/record that overlaps the proposed absolute window rejects a new V2 batch regardless of local `weekKey`; only an exact same commitment, generation, envelope, schedule-ID set, and record-content retry is idempotent. Live V1 state is never replaced. Expired owner records are pruned and their legacy artifacts are then removed.
4. **Active enforcement records provenance locally.** Root settings distinguish manual, test, legacy-schedule, and V2-scheduler blocks and retain the active record/revision/generation locally. Telemetry may upload only static source enums, booleans, and aggregate counts; schedule IDs, generations, policy revisions, dates, UIDs, bundle IDs, entries, and settings values never leave the machine.
5. **One serialized evaluator recomputes from wall time.** It runs at daemon startup, the next exact start/end boundary, wake, wall-clock/timezone change, schedule mutation, active-block completion, and a coalesced periodic backstop. Timers improve promptness; the root records and recomputation provide correctness.
6. **Manual and test blocks are never automatically replaced.** If one overlaps a scheduled window, reconciliation defers and retries at its end/backstop. This preserves the existing fail-safe arbitration and avoids making a schedule migration an implicit block-replacement feature.
7. **The current one-minute inter-segment compatibility gap remains in this cutover.** Removing it requires an independently verified PF/hosts/AppBlocker replacement primitive that stages the new policy before dropping obsolete rules. The scheduler migration must not implement remove-then-add and call it gapless.
8. **Diagnostics become backend-aware.** V2 consistency is desired records to root records to applied provenance/physical layers. Plist and loaded-job checks apply only to draining V1 records. Successful no-op timer evaluations are not emitted; reconciliation anomalies use the existing daemon spool and typed allowlists.
9. **Committed policy changes remain monotonic.** Strictification may add entries to V2 records, but cannot remove them. If the matching V2 record is currently active, the daemon physically applies and verifies the active append while holding the same mutation lock before persisting the stricter root record. Active provenance matching also requires commitment, generation, mode, and blocklist content; a weaker active policy never counts as reconciled.

## Consequences

- New schedules run before login, after reboot, and after wake without depending on GUI-session Background Items permission or an absolute CLI path.
- The legacy bridge remains temporarily larger than the final architecture, but it is no longer used for V2 writes and can be deleted after the maximum current-plus-next-week commitment horizon and release evidence.
- Exact active-to-active policy replacement and removal of the compatibility gap remain a separate, testable follow-up rather than being hidden inside the authority migration.
- A V2-capable app requires daemon protocol version 5 and the root-scheduler capability; the existing repair-on-launch handshake installs the matching helper.
- A crash after root persistence but before the local manifest write remains visible as an app-side recovery problem, but it is no longer an enforcement escape: the root envelope rejects a different overlapping commitment until expiry.

## Rollback

Reverting the app to V1 leaves existing V1 jobs untouched. A V2-capable daemon continues enforcing already-persisted V2 records independently of the app, and rejects legacy registration that overlaps an unexpired V2 envelope. After those V2 envelopes expire, disabling V2 commitment creation restores the old per-segment path without converting or deleting unrelated weeks or users.
