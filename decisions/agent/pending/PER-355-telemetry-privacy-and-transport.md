# PER-355: Telemetry privacy and transport

## Status

Core implementation complete locally on `codex/per-355-sentry-telemetry`; pending maintainer review. Production DSN/IP/dSYM smoke validation, SCSettings permission migration, upload budgets, identity/render ledger, CLI-unreachable spool, one-shot support consent, and signed XPC integration proof remain explicit release/follow-up gates in `docs/TELEMETRY.md`.

## Context

Fence needs enough cross-process evidence to diagnose app-state loss, schedule drift, committed strictification failures, and physical blocker failures. The daemon must retain diagnostics when the app is not running, while Fence's consent promise forbids uploading blocklists, identity data, or free text.

## Decisions

1. **No fixed unsalted blocklist fingerprint in v1.** Compare raw lists locally and upload only equality booleans, structural counts, and count deltas. If cross-event correlation later proves necessary, use an opaque revision or a per-install keyed HMAC over the canonical deduplicated representation; never upload the key.
2. **Daemon diagnostics use a per-user, daemon-owned spool exposed through authenticated XPC fetch/ack.** The daemon owns a `0700` directory and `0600` records, filters by the calling UID locally, bounds and atomically rotates records, and revalidates every record before returning a sanitized batch. The app never directly reads a world-readable root spool.
3. **Telemetry schemas are typed allowlists.** Event builders define allowed fields, types, ranges, and static messages. Arbitrary tag/context dictionaries and automatic activation of legacy Sentry call sites are not accepted as a privacy boundary.
4. **Consent is Fence-specific and per user.** Unknown or stale consent means do not record or upload. Opt-out purges queued daemon records and Sentry envelopes, including corrupt/symlinked-marker cases. One-shot Report a Problem consent is the intended policy but is not implemented in this slice; current support correlation requires global Fence telemetry consent.
5. **Physical postconditions are authoritative.** Block start, strictify, integrity reapply, and teardown return structured per-layer results. Settings state is not treated as proof that hosts, PF, or app monitoring changed successfully.
6. **Daemon compatibility is based on a monotonic protocol/build capability handshake, not marketing-version ordering.** Missing required capabilities triggers one reinstall attempt and a post-reinstall verification.
7. **The bundle-ID repair is conservative and one-shot.** Restore legacy SelfControl schedule, commitment, and credit keys only when the current Fence defaults domain has no schedule state. Never overwrite or merge into a calendar already created under Fence; report partial-state divergence instead of silently rewriting it.
8. **Unavailable secured settings fail closed for enforcement.** Initial missing/corrupt/unreadable/schema-invalid state is distinct from valid idle defaults. Automatic expiry/remnant teardown and ordinary mutation/persistence are suspended while settings are unavailable; a valid later reload or the narrowly scoped first-run missing-file bootstrap restores enforcement availability. Transient reload failures retain the last-known-good in-memory state.
9. **Spool identity is retry identity, not user identity.** Each record gets a random UUID reused as the Sentry event ID for idempotent fetch/ack retries. The queue is bounded to 100 records/256 KB per UID, filters records older than 14 days on activity, and rejects excessive future skew. Persistent upload budgets remain a separate gate.

## Consequences

- The real-SDK fake-transport privacy suite passes, but Sentry remains disabled by an empty DSN until a Fence-owned project, server-side IP suppression, dSYM upload, and exact-release smoke event are verified.
- More XPC surface and result plumbing are required than the original direct-file spool proposal.
- Local equality checks provide stronger diagnosis than uploaded hashes without creating a globally linkable blocklist identifier.
- Current support references are available only under global consent. One-shot support consent is deferred and must never drain historical records.

## Rollback

The new telemetry pipeline remains behind an empty-DSN kill switch. Removing the drainer and capability calls leaves existing blocking behavior intact; daemon protocol methods remain additive.
