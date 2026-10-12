# PER-444: Remove the first-run safety check

Approved by the user on 2026-10-12 after investigating Sentry FENCE-MACOS-B.

Remove the automatic first-run safety-check prompt and diagnostic sequence: the
user considers it alarming to new users. Also remove its automatic follow-up
Test Block offer, including the launch-time offer for users who previously
completed the check. Launch proceeds without consulting safety-test completion.

Keep the explicitly selected Test Block menu action and the manually invoked
Debug-menu safety-check tool. The latter has no production AppController entry
point. Daemon compatibility, schedule consistency telemetry, and physical
blocking checks continue independently.

This is an onboarding change, not a claim that the two observed Sentry
consistency events were definitively caused by the safety check. No preference
migration, telemetry schema change, or deployment is included.
