# PER-355: Sentry-only diagnostic reports

## Decision

Fence exposes two distinct status-menu controls:

1. **Send Anonymized Error Reports** controls ongoing consent-gated automatic crash and typed-failure telemetry.
2. **Send Diagnostic Report Now…** captures one fresh, privacy-safe app/UI/daemon snapshot in Sentry and shows a `FENCE-<event-id-prefix>` reference.

The manual report requires the existing global Fence telemetry consent. It does not silently enable reporting or drain data created before consent. Fence no longer exposes or implements the local unified-log export, Finder reveal, email draft, or attachment workflow.

## Privacy boundary

The report contains only typed allowlisted enums, booleans, and bounded counts. It may compare persisted, decoded, model, created-view, geometrically visible, and effectively visible calendar state plus exact aggregate daemon enforcement and schedule projections. It never includes bundle names or identifiers, websites, app names, schedule times or coordinates, block frames or colors, blocklist entries, email, identity, paths, raw logs, screenshots, or attachments.

## User experience

Fence shows progress while collecting and flushing the snapshot. Success displays a copyable `FENCE-` reference; failure tells the user to verify consent and connectivity. This confirmation is the deterministic support handoff, while automatic telemetry continues to report qualifying failures without user action.

## Consequences

- Support can distinguish missing persisted data, decode loss, model/render divergence, empty calendar presentation, and daemon-only enforcement.
- Support can distinguish block-view objects that exist from blocks with zero/clipped geometry or no visible appearance, and can see exact approval/plist/loaded-job drift in the same referenced event.
- Users do not need to locate a hidden macOS Help menu or manually attach files.
- Deep raw-log collection is intentionally unavailable; future diagnostics must extend the typed schema instead.

## Rollback

Remove the status-menu action and its `support.diagnostic_snapshot` UI fields. The existing automatic Sentry lifecycle and daemon spool remain independent.
