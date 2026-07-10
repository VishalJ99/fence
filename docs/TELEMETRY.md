# Fence Telemetry Policy (Sentry)

> **Status:** PRODUCTION ENABLED in Fence 3.4.8 (build 648) under PER-355. Core remote diagnostics are released; §2.2 lists bounded gaps and follow-up hardening. The audit decisions in §12 are recorded in `decisions/agent/pending/PER-355-telemetry-privacy-and-transport.md` for final maintainer review.
> **Date:** 2026-07-10
> **Purpose:** Define what diagnostic data Fence sends to Sentry (essential vs. good-to-have), what it must NEVER upload, and how the policy is enforced structurally rather than aspirationally.

---

## 1. Why this document exists

Fence's users report bugs by email. The maintainer needs Sentry to answer "what happened on that machine" without reading code and reasoning from git logs. The motivating incident: **an app update wiped a user's weekly calendar while their blocks kept enforcing.**

A concrete mechanism for that symptom exists in the code: the SelfControl→Fence rebrand changed the bundle ID (`org.eyebeam.SelfControl` → `org.eyebeam.Fence`), which switched the `NSUserDefaults` domain while daemon settings and fixed-label launchd jobs survived. That can produce an empty calendar UI while blocks keep enforcing. It is not safe to declare that the cause of every report without a machine snapshot: the same symptom can also come from decode loss, a retained daemon, approval/job drift, or a UI-only render regression. The diagnostics below distinguish those classes instead of guessing from the symptom.

**Guiding constraint:** Sentry is event-based and event-billed. We define few, high-signal event types with rich sanitized context and a breadcrumb trail — not a log firehose.

## 2. Current integration

Sentry **9.14.0** is linked only into the app. Root components never initialize a network SDK: they write pre-sanitized typed records to a daemon-owned per-UID spool, and the signed app fetches and uploads them after explicit Fence consent. `Common/SCSentry.m` is the only outbound boundary. The consent prompt promises: *"All data is anonymized, your blocklist is never shared, and no identifying information is sent."* That promise is the contract this policy enforces.

### 2.1 Implemented diagnostic coverage

| Area | Current implementation |
|---|---|
| Consent and SDK lifecycle | Explicit Fence opt-in is required before startup; a checkmarked `Send Anonymized Error Reports` status-menu item exposes the current choice; root is prohibited; opt-out stops transmission without flushing and purges Fence/known legacy caches |
| Privacy boundary | Typed event schemas, allowlisted fields/enums, sanitized errors/contexts/breadcrumbs, final serialized-payload tripwire, attachment-free capture API plus zero attachment-size ceiling, no raw settings/defaults, no Sentry user ID, and automatic network/hang/session/log/tracing channels disabled |
| Release identity | Component-specific release + build dist, production/development environment, empty/placeholder/upstream-DSN kill switch, and a release script that requires/uploads the matching dSYM when a DSN is configured; the 3.4.8/build 648 production dSYM and symbolication smoke are verified live |
| URL/block parsing | One canonicalizer is shared by UI, block model, daemon apply, strictify, and comparisons. Schemes, paths, queries, case, IDNA, ports, CIDR, and trailing slashes are normalized before enforcement |
| Physical enforcement | Fresh apply, strictify, integrity reapply, and teardown return typed hosts/PF/app/settings postconditions; state mutation alone is not success |
| Strictify | One aggregated `block.strictify_result` covers active and future commitments, exact preconditions, retry-safe union handling, physical apply, settings persistence, timeout, and token-scoped overlapping retries |
| Daemon transport | Protocol v4; root-owned `0700` per-UID spool with `0600` files, audit-token UID isolation, atomic locked rotation, 100-record/256-KB bounds, 14-day activity-driven GC, future-skew rejection, typed revalidation, stable retry IDs, consent generations, and opt-out purge |
| State consistency | Startup sends the app's expected projection over authenticated local XPC; the daemon compares canonical active entries, root approvals, validated plists, and actually loaded launchd jobs, returning only match booleans and missing/extra counts plus physical-layer state |
| Failure paths | Typed events cover settings-load failure, code-signature/XPC rejection, non-cancelled authorization rejection, unreachable-daemon reinstall outcomes, incompatible daemon repair, schedule commit/install/execute, block apply/teardown, strictify, and verified emergency unlock |
| Support | Help → Export Logs for Support captures a sanitized structural snapshot when globally opted in and puts `FENCE-<event-id-prefix>` in the support email/log header; email log files are protected and scrubbed |

For the motivating incidents this is enough to answer, without blocklist contents: whether app calendar/default state disappeared, whether the daemon retained active/approved state, whether a newly added entry canonicalized, whether it targeted the active block and/or future jobs, whether preconditions matched, and which hosts/PF/app/persistence postcondition failed.

### 2.2 Remaining hardening work and bounded gaps

The production DSN is configured in 3.4.8/build 648 and the original external release gate is closed. Items 2–4 remain follow-up hardening and bound what support can infer; they do not disable the released consent-gated diagnostics.

1. **Completed for 3.4.8/build 648:** the Fence-owned `scattered-minds/fence-macos` project has IP suppression and default data scrubbing enabled; the public DSN is injected at release build time; dSYM UUID `4d06898a-5154-34ca-8ba3-c43258fa18e3` is present in Sentry; and exact-release smoke event `93c1405cc7cc4382ae4ed719a7a10a09` symbolicated to `main` for `fence-app@3.4.8+648`, dist `648`.
2. Move all non-root SCSettings reads behind authenticated XPC, then migrate Fence's plist into a dedicated root-owned `0700` directory with a `0600` file (do not chmod the shared `/usr/local/etc` directory). Tightening the current file alone would make the app/CLI read defaults and can hide a live block.
3. Add the brand-stable identity/count ledger and a real calendar-render projection if UI-only disappearance (model present, views absent) must be distinguished remotely. Current startup checks prove persisted/decoded/app/daemon/physical consistency, not AppKit rendering.
4. Add a persistent per-event/release upload budget, a user-owned CLI spool for failures where the daemon is unreachable, a signed multi-user XPC integration test, and one-shot support consent. The spool already has hard count/byte/age bounds, but these operational controls are still missing.

Sections 3–13 are the target policy/acceptance contract. Where they are more ambitious than §2.1, §2.2 is authoritative about the current implementation.

### 2.3 Original hazards and disposition

| # | Hazard | Where | Impact |
|---|--------|-------|--------|
| U1 | ~~DSN points at upstream SelfControl's Sentry org~~ | `SCSentry.m` | **Fixed:** removed; upstream/placeholder DSNs fail closed |
| U2 | ~~`ApprovedSchedules` attached to Sentry context~~ | `SCSettings.m`, `SCSentry.m` | **Fixed:** contexts are constructed from safe scalar/count allowlists only |
| U3 | ~~Raw/dead-domain defaults context~~ | `SCSentry.m` | **Fixed:** current defaults are filtered through a safe allowlist; license and schedule values cannot enter the event |
| U4 | ~~Incorrect environment/release~~ | `SCSentry.m` | **Fixed:** production/development, component release, and build dist |
| U5 | ~~Root failures are no-ops~~ | `SCTelemetrySpool`, daemon XPC | **Fixed for essential daemon paths:** root spools typed events and never transmits directly; unreachable-daemon CLI reporting remains gated in §2.2 |
| U6 | ~~World-readable `/tmp` diagnostics~~ | daemon/schedule launchd | **Fixed:** removed; schedule stdout/stderr go to `/dev/null` |
| U7 | ~~Sensitive runtime/support logging~~ | daemon/app/CLI/`SCLogger` | **Mitigated:** known raw blocklist/auth/device/settings logs were removed, unified-log export is scrubbed, and support files/directories are `0600/0700`; keep this sanitizer under review as call sites evolve |
| U8 | ~~Automatic Sentry identity/network/hang channels~~ | `SCSentry.m` | **Fixed and covered by a real Sentry 9.14 fake-transport envelope test** |
| U9 | The supposedly secured SCSettings plist is chmod `0755` even though it contains `ActiveBlocklist` and `ApprovedSchedules` | `SCSettings.m:303-317` | Every local account can read the complete active and scheduled blocklists; direct app reads also prevent safely tightening it to `0600` |
| U10 | ~~`Secrets.xcconfig` in Copy Bundle Resources~~ | Xcode project | **Fixed:** it is configuration-only, not a copied resource |
| U11 | ~~No dSYM upload step~~ | `scripts/build-release.sh` | **Fixed and verified live for 3.4.8/build 648:** matching dSYM uploaded and exact-release smoke symbolicated |

## 3. The NEVER-upload list (the contract)

These must never appear in any Sentry event, breadcrumb, log, tag, or context — enforced by allowlists and sanitizers (§9), not by per-call-site discipline:

1. **Blocklist entries in any form** — domains, hostnames, IPs, ports, `app:` bundle IDs — whether from `Blocklist`, `ActiveBlocklist`, `ApprovedSchedules`, `.selfcontrol` files, or NSError userInfo. Only local comparison results and structural counts leave the machine.
2. **User-named bundle names** and schedule *contents* (specific days/times/windows). Only counts, enum outcomes, and local equality/delta results.
3. **`FenceLicenseCode`** (embeds the user's email), anything from `SCLicenseManager` payloads, iCloud KVS values, trial dates tied to identity.
4. **Device identity** — raw serial number, `IOPlatformUUID`, `SCDeviceIdentifier` hashes, the settings filename hash.
5. **Usernames / home paths** — no absolute path under `/Users/`; basenames or `$HOME`-stripped templates only.
6. `/etc/hosts` contents, PF anchor/rule text, resolved IPs, browser cache paths.
7. Raw `NSUserDefaults`/`SCSettings` dumps; raw NSError `userInfo`; `NSUnderlyingError` chains.
8. Unified-log excerpts (the SCLogger email export never goes to Sentry).
9. Free text typed by the user, anywhere.

Safe by definition: counts, booleans, enum tags, error domain+code, durations, bucketed time deltas, our own bundle IDs/versions, macOS version, locale. Raw UIDs and exact schedule/block timestamps are not safe; compare them locally and upload only `current_user_match` or delta buckets.

## 4. ESSENTIAL tier — must exist before telemetry is trusted

Conventions: `event(app)` = direct SDK capture in-app · `event(spool)` = written by daemon/CLI to the spool (§6), uploaded by the app · all events are tagged with `origin` (`app`|`daemon`|`cli`) and, when applicable, `spooled` · the static event name is the message/grouping boundary; caller-supplied fingerprints are cleared · payloads are counts/booleans/enums only.

| # | Event | Trigger (where) | Level | Key tags | Context payload |
|---|-------|-----------------|-------|----------|-----------------|
| E1 | `state.app_daemon_diverged` | Startup checker (§7), fired only when ≥1 invariant fails | error | `reason`, `collector_status` | App raw/decoded counts; exact active/approval/plist/loaded-job equality and missing/extra counts; daemon state counts; settings availability and physical hosts/PF/app booleans. Identity-ledger/render fields remain a §2.2 gap |
| E2 | `state.app_defaults_regressed` | Legacy-domain repair restores an orphaned calendar, or raw persisted bundle/schedule rows fail to decode | error | `reason` (`legacy_domain_orphaned`\|`decode_loss`) | Current/legacy structural counts only; never raw values. `bundle_id_changed` and `unexplained_drop` remain reserved for the §2.2 identity ledger |
| E3 | `daemon.settings_load_failed` | SCSettings initial load/reload rejects missing-after-initialization, unreadable, malformed, version-invalid, or schema-invalid state | error (spooled) | `reason` | settings version, error code, recovery attempted/succeeded. Last-known-good state is retained; initial unavailable state blocks automatic teardown and ordinary settings mutation/persistence until a valid snapshot recovers |
| E4 | `block.teardown_failed` | Verified teardown leaves any hosts/PF/app/settings postcondition uncleared | error (spooled) | `layer` (`hosts`\|`pf`\|`apps`\|`settings`) | Per-layer removal booleans, overall verification, duration, and bounded error code. Callers retain declared state and retry instead of reporting success |
| E5 | `block.apply_failed` | Shared `SCBlockApplyResult` for fresh start, strictify append, and integrity reapply; emit when a required layer or persistence postcondition fails | error | `operation` (`fresh`\|`strictify`\|`integrity_reapply`), `layer`, `is_allowlist` | Requested/canonical/rejected counts by type; hosts readiness/write/verify status; PF anchor-open/write/refresh/verify status; DNS resolved/total; app-monitor before/after and kill-failure count; settings-persisted; duration. **State mutation alone is never success** |
| E6 | `xpc.connection_rejected` | Daemon listener cannot inspect a client or the signed-code requirement fails; clause checks distinguish identifier/team/min-version failure | error (spooled) | `stage`, `client_id` | OSStatus, `{identifier_ok, team_ok, version_ok}`, safe client version. Deduplicated once per client/daemon run |
| E6a | `xpc.auth_rejected` | A start/update/schedule/install/permission-repair Authorization Services check fails for a reason other than ordinary user cancellation | error | `command` | Safe OSStatus code only; once per command per app run. User-cancelled prompts do not emit an incident |
| E7 | `daemon.unreachable_reinstall` | Capability handshake cannot reach a daemon that should exist, triggering the one allowed reinstall | error | `outcome` (`recovered`\|`install_failed`\|`post_repair_unreachable`\|`post_repair_incompatible`) | Enumerated initial/final failure class, bounded error codes, bundled/installed-helper presence before/after, reinstall result, reconnect attempted, and post-repair handshake/compatibility booleans. No raw XPC or install error text |
| E8 | `schedule.exec_failed` | CLI/XPC start rejection, daemon recovery, or block-start failure | error | `path` (`cli_launchd`\|`daemon_recovery`\|`xpc_direct`) | minutes-late bucket, approved/list counts, block-already-running, error code; no schedule ID |
| E9 | `schedule.commit_install_failed` | Aggregated transactional commit failure; partial launchd jobs and root approvals are rolled back and commitment is not persisted | error | `stage` (`daemon_install`\|`schedule_register`\|`job_install`\|`verification`) | segments planned/installed, error code, week offset |
| E10 | `emergency.unlock_result` | Emergency script returns fixed root-side settings/hosts/PF postconditions; credit and UI state change only after verified cleanup | info (verified success) / error | `outcome` (`success`\|`script_error`\|`verify_failed`) | AppleScript error code, `{settings_cleared, hosts_clean, pf_check}`, credits remaining, duration |
| E11 | `tamper.no_block_found` | Checkup finds Fence physical remnants while declared block state is inactive | warning/error (spooled) | `remnants` (`hosts`\|`pf`\|`apps`\|`multiple`) | per-layer remnant booleans, settings version, and teardown verification; deduplicated once per daemon run |
| E12 | App crashes | SDK automatic after privacy containment and dSYM pipeline are verified | — | — | A sanitized structural scope is initialized after state load and refreshed after state changes; no Sentry installation user, automatic URL breadcrumbs, app-hang events, screenshots, or raw SDK contexts |
| E13 | `support.diagnostic_snapshot` | Existing Help → Export Logs for Support flow while global Fence telemetry consent is enabled | info | `collector_status`, `last_strictify_outcome` | Basic app/daemon structural counts, reachability, settings/physical-layer state and match booleans; event ID is cross-referenced in the support email. Full one-shot/E1-style support capture remains a §2.2 gate |
| E14 | `block.strictify_result` | Once per committed bundle edit containing additions, after both active and future paths and physical postconditions complete | info for verified success; error otherwise | `outcome`, `target`, `failed_stage`, `daemon_protocol` | Per-run operation sequence; added/canonical/rejected/duplicate/app/site counts; committed/current-segment status; active expected/precondition/reapply/verified counts; future candidates plus loaded-job/probe counts; approvals requested/matched/updated/skipped-by-reason; per-layer result; settings persistence. This is the essential event for "added site not blocked" |
| E15 | `daemon.incompatible` | Capability handshake remains incompatible after its one repair attempt | error | `reason` | Safe daemon build/marketing version, protocol, and repair attempted/succeeded booleans. Compatibility is never inferred from marketing-version ordering |

## 5. GOOD-to-have tier

| # | Name | Trigger | Mechanism | Notes |
|---|------|---------|-----------|-------|
| G1 | `block.started` | `SCDaemonBlockMethods` verified-success path | crumb (spooled) | Canonical counts, required-layer results, local declared-vs-actual equality, and end-delta; **replaces** the NSLog that prints the full blocklist (delete it — U7) |
| G2 | `block.integrity_reapplied` | integrity check reapply | crumb; escalates to event at ≥3 reapplies per block session | repeated reapply = tampering or a fighting MDM/VPN tool |
| G3 | `settings.sync_failed` | existing SCErr 600/601 sites | keep as event, throttled max 3/run/code | today can fire every 30s sync tick on a wonky disk |
| G4 | `xpc.interrupted`/`xpc.invalidated` | `SCXPCClient` handlers | crumb + session counter attached to later events | |
| G5 | `safety_check.failed` | `SCStartupSafetyCheck` result with issues | event(app) | issue strings are static templates — safe |
| G6 | `schedule.stale_cleaned` | daemon/CLI stale-schedule cleanup | crumb (spooled) | segment UUID + reason |
| G7 | `app.repair_migration_applied` | `AppController runPostUpdateRepairMigrations` | crumb | which migration, before/after counts |
| G8 | `license.activation_failed` | `SCLicenseManager` server-error paths | event(app) | error code only — never the code/email |
| G9 | `update.daemon_reinstalled` | version-mismatch reinstall path | crumb | version pair |
| G10 | `dns.partial_resolution` | `BlockManager ipAddressesForDomainName` failures | context fields on E5/E14/G1 only | never per-domain records |

## 6. Daemon/CLI transport: spool-and-forward

The daemon is where enforcement failures often occur. **Implemented decision: the daemon writes pre-sanitized typed records to a spool; the app uploads them through its existing consent-gated SDK.** CLI-triggered schedule failures reach that daemon spool; a separate user-owned queue for failures that cannot reach the daemon remains a §2.2 gate.

Rejected alternatives: *(a) link the pod into the daemon* — Sentry 9.x static linking already failed on this repo's toolchain for a plain app target (`Podfile:27` "incompatible with macOS 26 C++ toolchain"); an SMJobBless single-binary helper is strictly harder; and it puts a third-party network stack inside a root process. *(c) live XPC relay to the app* — requires the app running at failure time, which is exactly false for launchd-fired schedules, reboots, and recovery paths.

Spec:
- `Common/SCSentry.{h,m}` owns the typed schema registry and outbound boundary; `Common/SCTelemetrySpool.{h,m}` is the pure-Foundation daemon queue. Every accepted event has allowlisted fields/types/ranges and a maximum serialized size. There is no arbitrary public tags/context API.
- The daemon owns `/usr/local/etc/fence-telemetry/` as `0700`, with a separate `0600` bounded queue per controlling UID. Writers use file locking, reject symlinks/non-regular files, cap individual record size/depth, and rotate atomically. A separate user-owned CLI queue is not yet implemented.
- Record: `{id, schema_version, event_name, level, origin, created_at_ms, fields}`. The random record ID is reused as the Sentry event ID so fetch/ack retries deduplicate without a stable user/install identifier.
- Caps: max 100 records / 256 KB per user, 16 KB per record, 25 per fetch. Records older than 14 days and timestamps more than five minutes in the future are removed on queue activity. A persistent per-name/discriminator/release upload budget is still a §2.2 gate. Per-checkup/timer successes never enter the spool.
- Fence-specific consent is stored per user with a generation number and propagated to the daemon. Unknown/stale/off means do not record. Opt-out deletes daemon/user spools and closes/purges Sentry cached envelopes. The transport never treats the system crash-reporting preference as Fence consent.
- New authenticated XPC methods fetch a bounded sanitized batch for the calling UID and acknowledge uploaded IDs. The daemon derives the UID from the accepted connection audit token, never trusts a caller-supplied UID, revalidates every record at fetch time, and compacts only after acknowledgement. Tightening SCSettings to `0600` therefore does not break the checker or drainer.
- The app captures each spooled event with a temporary per-event scope containing only preceding breadcrumbs from the same `run`/operation. It never replays daemon breadcrumbs into the global scope. Original timestamps are clamped and tagged for clock skew.
- Accepted cost: no native crash reports for the daemon itself (its failures are logic failures, which we instrument).

## 7. Startup state-consistency check (catches the calendar-wipe class)

The checker is split across `SCScheduleManager` (local structural snapshot and expected projection), `AppController` (capability-gated orchestration/retry/emission), and `SCDaemonXPC` (root-state, plist, launchd, and physical probes). It starts only after the capability handshake. The app sends entries/dates only across the authenticated local XPC boundary; the daemon returns counts, match booleans, status enums, and physical booleans only.

**Planned identity/state-transition marker (not implemented):** `~/Library/Application Support/SelfControl/app-identity.plist` — `{schemaVersion, lastBundleID, lastAppVersion, lastBuild, lastLaunchAt, firstSeenAt, lastStructuralCounts, lastIntentionalResetReason}`. This remains necessary for unexplained cross-launch regressions and is tracked in §2.2.

| Code | Invariant | Catches |
|------|-----------|---------|
| I1 | Current-user nonexpired approvals/jobs or an active scheduled block ⇒ app has decoded bundles and schedules for the relevant week | Full or partial calendar/defaults loss while enforcement survives |
| I2 | Raw persisted bundle/schedule rows == decoded rows, and decoded rows == manager/cache projection | Malformed rows silently dropped or a stale cache |
| I3 | When the calendar is open, model allow-window count == rendered projection count; empty is allowed only when `expected_empty_calendar=true` | UI-only calendar regressions versus intentional all-week blocking |
| I4 | Every committed enabled bundle has a current/next schedule with a valid bundle reference | Orphan schedules and missing bundle schedules |
| I5 | App-derived nonexpired segments correspond to current-user approvals, valid plists, and loaded launchd jobs, with in-progress direct-start segments explicitly exempted | Registration/job drift without stale-state false positives |
| I6 | App-derived expected content equals each corresponding approval locally; upload only match booleans and count deltas | A correct UUID with an outdated blocklist |
| I7 | Expected current active content equals `ActiveBlocklist` locally | Strictify skipped or state mutation lost |
| I8 | `BlockIsRunning` agrees with required physical layers for the active entry types and mode | Settings claim success while hosts/PF/app enforcement is missing |
| I9 | `BlockIsRunning && BlockEndDate < now - 300s` is false | Expired-but-stuck block |
| I10 | Required daemon protocol/build capabilities are present | Retained 6.4.5 daemon lacking strictify selectors |
| I11 | Previous brand-stable structural counts have not regressed without an intentional reset/migration reason | App defaults loss even when `SCHasEverCommitted` disappeared too |
| I12 | Known legacy domains do not contain more current/next structural state than the current domain | First telemetry-enabled launch after the bundle-ID change |
| I13 | Test blocks and safety-check fixtures are classified separately from committed production state | Avoid I1/I8 false positives during deliberate tests |
| I14 | Daemon snapshot, launchd queries, and physical probes each report `ok` rather than being coerced to zero/false on timeout/unreadable/unreachable | Collector failure cannot masquerade as clean state |

Emission: violations → one E1 event with the full dual-sided payload; clean → single breadcrumb. Identical violation set within 7 days → breadcrumb only (a persistently broken state must not emit daily events).

## 8. Cross-layer blocklist comparison

**Decision for v1: do not upload a blocklist fingerprint.** A fixed unsalted hash of a small list of popular sites is dictionary-enumerable and globally linkable. It is also unstable unless every producer shares exactly the same canonicalization and deduplication rules.

The app/daemon snapshot collector reads the raw lists locally, canonicalizes and deduplicates them with the same shared parser, and uploads only equality booleans plus expected/actual/missing/extra counts. This is stronger diagnostic evidence than comparing two opaque hashes and does not create a reusable identifier for the user's list.

If later dogfooding proves that cross-event correlation is indispensable, use either an opaque revision UUID propagated with the block state or a per-install keyed HMAC. Never upload the key, never put the value in a Sentry tag, and keep local equality/count fields as the authoritative diagnosis.

## 9. Privacy enforcement (structural)

1. **Typed allowlists, not denylist cleanup.** Each event builder owns its safe schema. App defaults context includes only safe preferences/flags and derived structural counts. Daemon context comes from a sanitized XPC snapshot containing state booleans, delta buckets, counts, local match results, and collector statuses. Never attach raw `NSUserDefaults`, SCSettings, SDK-generated device/user contexts, exact `BlockEndDate`, `ApprovedSchedules`, or arbitrary dictionaries.
2. **`sanitizedError:` choke point** inside `captureError:` and the spool writer keeps only domain+code plus an internal safe reason enum chosen by the typed caller. Drop `localizedDescription`, `userInfo`, `NSUnderlyingError`, paths, and dynamic `SCErr subDescription` text.
3. **Message strings are hardcoded templates only.** Dynamic values travel exclusively through fields declared by the event schema. Unknown fields, object types, enum values, or error domains are dropped or mapped to `other`; arbitrary object `description` is never serialized.
4. **Planned upload budget:** persist a per-release counted set keyed by event/discriminator and acknowledge budget-dropped spool records. Hard spool count/byte/age caps exist now; the cross-drain upload budget remains a §2.2 follow-up.
5. **Privacy tripwire:** pure serializer tests and an SDK-enabled fake-transport integration host traverse only user-controlled event fields/breadcrumb data and reject sentinel blocklist values, usernames, home paths, emails, license/device tokens, raw UIDs, undeclared keys, and every non-event envelope item. Do not use a blanket `@` substring check because the valid release name itself contains `@`.
6. **SDK containment before DSN enablement:** remove the hardcoded upstream DSN and leave the SDK disabled when the Fence-owned DSN is absent. Explicitly clear Sentry's installation `user.id`; set `sendDefaultPii=NO`; disable network/automatic breadcrumbs, failed-request capture, app hangs, logs, screenshots, view hierarchy, sessions, tracing, and profiling unless separately ratified. Add `beforeSend`, `beforeBreadcrumb`, and `beforeSendLog` defense in depth. Enable Sentry's project-side **Prevent Storing IP Addresses**. Environment is `development`/`production`; release is `fence-app@<version>` and dist is the build number.
7. **Build-secret and symbol hygiene:** the public DSN may be injected as a build setting/Info value, but `SENTRY_AUTH_TOKEN` stays only in the release environment/keychain. Remove `Secrets.xcconfig` from Copy Bundle Resources and verify/rotate separately. Upload and verify the matching dSYM before publishing each release.
8. **On-disk/support-log hygiene:** delete `/tmp` debug logs and blocklist/authorization/device/settings-printing NSLogs. Move schedule stdout/stderr to a protected Fence log directory or disable them. The support export uses a category allowlist or mandatory sanitizer; it never sends raw unified-log excerpts to Sentry.
9. **Structured Sentry logs remain disabled for v1.** Bounded breadcrumbs provide event context. Re-enable logs only after a distinct typed schema, volume budget, and privacy review.
10. **Flagged follow-up (not in scope):** Sparkle `SUEnableSystemProfiling`/`SUSendProfileInfo` are `true` in Info.plist — anonymous system profiles go to the update feed host on check, which sits awkwardly next to "no identifying information is sent." Decide separately.

## 10. Implementation order

| Phase | Content | Size |
|-------|---------|------|
| 0 | **Contain and repair:** empty-DSN kill switch; remove upstream DSN and unsafe SDK defaults; remove `Secrets.xcconfig` resource; add daemon protocol/build capability handshake, retained-6.4.5 reinstall, known legacy-domain probe/migration; focused regression tests | ~2 days |
| 1 | **Privacy foundation:** typed schemas/serializer, Fence consent broker, safe Sentry scope/error/breadcrumb handling, fake transport tests, server-side IP setting, release/env/dist naming, dSYM upload/verification | ~2 days |
| 2 | **Canonical enforcement results:** shared strict entry canonicalizer; `SCBlockApplyResult`, `SCBlockTeardownResult`, and aggregated `SCStrictifyResult`; physical postconditions and settings persistence; UI retry/failure path | ~3–4 days |
| 3 | **Secure daemon transport:** per-user daemon spool, authenticated XPC sanitized snapshot/fetch/ack, rotation/locking/limits/consent purge, multi-user and adversarial-file tests | ~2–3 days |
| 4 | **Essential events:** E3–E15 using the typed results, with strictify implemented first; XPC, schedule, emergency, apply, teardown, and compatibility fault injection | ~2 days |
| 5 | **Corrected consistency/support:** raw→decoded→cache→render checks, expected schedule graph comparisons, legacy transition ledger, support snapshot and optional selected-entry probe | ~2 days |
| 6 | **Release validation:** dSYM/event smoke, privacy canaries, VM failure matrix, one-week dogfood bloat audit, SYSTEM_ARCHITECTURE/index/decision promotion | ~1 day plus dogfood |

## 11. Support workflow tie-in

The existing Help → Export Logs for Support flow requests one current sanitized daemon snapshot, combines it with a bounded app structural snapshot, captures `support.diagnostic_snapshot` (E13) when global Fence telemetry consent is enabled, and puts `FENCE-<first 8 of Sentry event ID>` into the mail subject/body and sanitized log header. Without global consent (or without an active DSN), the email/log export still works but has no remote event reference. Support capture does not tag or drain historical spool records.

**Planned follow-up:** if global telemetry consent is off, a future explicit one-shot confirmation may authorize exactly one current E13 snapshot. That flow is not implemented in this slice and must never enable global telemetry or drain history.

## 12. Implementation decisions

1. **Blocklist comparison:** local equality booleans and count deltas for v1; no uploaded fixed fingerprint. Opaque revisions or per-install HMAC require a later privacy review.
2. **User-triggered consent target:** a future confirm dialog may authorize one current E13 snapshot only. The current implementation requires global Fence telemetry consent; historical drain must never be implied by one-shot approval.
3. **Transport:** daemon-owned per-user spool with signed XPC snapshot/fetch/ack; no directly readable root spool.
4. **Schema:** typed event builders and an explicit registry; no arbitrary telemetry dictionaries and no automatic activation of legacy call sites.
5. **Compatibility:** monotonic daemon protocol/build capabilities, never marketing-version ordering.
6. **Authority:** physical-layer verification plus settings persistence determines success; declared block state alone does not.

## 13. Verification

- **Pure unit tests:** typed serializer rejects undeclared keys/types/ranges; error sanitizer strips descriptions/userInfo/underlying errors; authorization rejection classification skips cancellation and deduplicates by command; unreachable-daemon repair fixtures distinguish install failure from a failed post-repair handshake; app/daemon snapshot builders never expose raw lists, UIDs, paths, dates, license/device values, or SDK installation IDs; canonicalizer table covers plain host, slash, path/query, query-without-slash, mixed-case scheme, port, CIDR, wildcard port, app entry, whitespace, and invalid host.
- **SDK-enabled fake transport:** the test target compiles `SCSentry.m` alone through its non-`TESTING` branch while keeping lifecycle/cache mutation dormant. A real Sentry 9.14 client sends through an ephemeral `NSURLSession` intercepted by an in-process URL protocol (with a loopback-only DSN as a second fail-safe). The test gunzips and parses the final HTTP envelopes after SDK enrichment, requires each envelope to contain exactly one event item, and asserts they contain no attachment, sentinel entry (`canary-telemetry-test.example`), username/home path, email, license/device token, raw UID, automatic URL breadcrumb, SDK-generated `user.id`, or undeclared context.
- **Automated spool/XPC tests now passing:** unknown/off/stale consent rejection and opt-out purge; root storage permissions and hard caps; TTL/future-skew collection; corrupt/symlinked marker recovery; concurrent append/rotation with UID queue isolation; retry-safe acknowledgement; symlink/non-regular-file rejection; typed schema and privacy-tripwire rejection; ownership/window predicates.
- **Automated strictify/consistency tests now passing:** canonical URL/entry table; legacy opaque-entry preservation; capability rejection; token-scoped overlapping retries; typed active physical-reapply, future loaded-job, no-projection physical-remnant, and seven-day divergence-suppression predicates; exact hosts-file write verification.
- **Remaining manual/VM matrix:** retained 6.4.5 daemon repair; orphaned current defaults with live daemon schedules; missing/immutable hosts content; PF anchor/refresh failure; zero DNS resolution; first-app monitoring; settings persistence failure; unloaded/partial future schedules; signed multi-user XPC isolation; E4 teardown retry; E6 code-signature rejection; E6a managed-right failure; E7 real install/post-repair failures; E8 launchd execution failure; and E10 sabotaged emergency script.
- **3.4.8 release gate (closed):** uploaded dSYM, verified exact debug-file UUID, sent an exact release/dist production smoke event, confirmed symbolication, and published the notarized artifacts. After one week of dogfooding, target <1 automatic event/install/day excluding real incidents and explicit strictify/support actions.
- **Bloat audit after a week of dogfooding:** target < 1 event/install/day excluding incidents; anything routine gets demoted to crumb per §5's anti-bloat contract.

### Explicitly NOT instrumented (anti-bloat contract)

Per-checkup 1 Hz ticks and no-action integrity checks · SCErr 300 lock timeouts · ordinary authorization-prompt cancellation · routine successes other than the rare aggregated strictify result · 60s schedule-timer firings and no-op recovery exits · ordinary UI interactions · Sentry structured logs · automatic URL/app-hang/performance/session/replay signals · Sparkle checks · anything automatic when Fence telemetry consent is unknown/off. One-shot support consent is not yet implemented.
