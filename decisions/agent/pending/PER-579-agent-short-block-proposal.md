# PER-579: agent-requested short blocks — discussion proposal

Status: proposed; user discussion pending. No feature, CLI command, or discoverable
skill has been implemented or installed. Parent: PER-444.

## User outcome

“Block Codex for the next 20 minutes” adds a temporary restriction immediately.
“Deep work: only Terminal for 20 minutes” means the user explicitly chooses
Terminal as the allowed interactive app. Terminal is not a built-in exception: a
normal bundle or future short block can block it like any other user app.
Neither request can undo, pause, replace, or postpone an existing commitment.

## Current source evidence

Inspected canonical Mac mini checkout, initially clean, on 2026-10-20.
This is source inspection, not a live Terminal-blocking test or verification of
short blocks, which do not exist yet.

- `cli-main.m:44`: accepts `start` (`--start`/`--install` aliases), `--uid`,
  `--blocklist`, `--startdate`, `--enddate`, `--settings`, `--schedule-id`;
  also `is-running`, `print-settings`, and `version`.
- `cli-main.m:382`: `remove` exists in the parser but always exits
  `EX_UNAVAILABLE`. `print-settings` logs aggregate counts, not a policy export.
  There is no short-overlay or structured agent-status command.
- `Daemon/SCDaemonBlockMethods.m:395`: ordinary start rejects an already-running
  block. `Daemon/SCDaemonScheduler.m:743`: the scheduler defers while a
  non-scheduler/manual block runs. Using legacy start for this feature could
  postpone calendar enforcement.
- `Daemon/SCDaemonProtocol.h`: active-entry append and recurring/template
  strictification exist; neither provides independent per-request expiry.
  Appending Codex to a recurring bundle would change its future occurrences.
- `Block Management/AppBlocker.h`: app enforcement is a deny set of bundle IDs,
  monitored every 500 ms. `BlockManager.m:462` sends app entries to that deny
  set. Existing network allowlist mode is not an app “only Terminal” mode.
- `Block Management/AppBlocker.m:217` and `:246` enumerate `PROC_ALL_PIDS`;
  the scan has no process-owner UID filter. Authenticated request ownership
  therefore does not currently imply account-scoped app enforcement.
- `SCBundleEditorController.m:397-418`: Add App uses a navigable application-bundle
  picker, initially at `/Applications`, with no system-app or bundle-ID exclusion;
  Terminal can be selected at `/System/Applications/Utilities/Terminal.app` and
  stored as `app:com.apple.Terminal`. Its live Info.plist identity was checked.
- `Block Management/SCBlockEntry.m:45-52`, `BlockManager.m:461-464`, and
  `AppBlocker.m:95-100,169-185,275-295`: app entries reach the generic deny set;
  executable paths, including `/System` apps, resolve to bundle IDs and matching
  processes are terminated. No Terminal exemption exists in this source path.
  The `/System` condition at AppBlocker182 only surrounds a disabled debug log;
  the bundle ID is returned unconditionally. No live block was started.
- `Daemon/SCDaemon.m:509`: XPC already validates signed Fence app/CLI clients and
  team identity. Ownership is bound to the connection. Preserve that boundary.

## Proposed product behavior

Use the term **short block** in the interface. Treat it as an independent,
daemon-owned temporary commitment, displayed alongside the calendar with its
own countdown. Expiry removes only its own contribution; the UI can say “Codex
short block ends at 14:20; your calendar still blocks it until 17:00.”

Each request identifies targets and a duration. The daemon fixes the start and
deadline at admission. No early cancel, shortening, break, or edit that weakens
it. A subsequent stricter request adds another independently expiring layer.
Keep extension out of the initial surface unless there is a concrete need.

Short blocks must not introduce a built-in exemption for any user app, including
Terminal, in either deny-only or allow-only mode. The user chooses allowed/blocked apps explicitly;
allowing Terminal in one request does not make it globally unblockable.

An explicit request with clear targets and duration authorizes the operation;
do not add a mandatory second confirmation. Ask when duration, device, or app
identity is genuinely ambiguous. “Deep work” alone does not define either.
Resolve Codex to its installed app identity rather than guessing a bundle ID.
The target is the Mac running the helper, not all the user's devices.

Enforcement account scope is unresolved. Recommend restricting new short-block
app enforcement to processes owned by the requesting account, including across
fast user switching. Do not silently apply “only Terminal” to every logged-in
user. This requires explicit implementation and tests; it is not a property of
the current machine-wide process scan. Preserve existing commitments while
making this choice; do not reinterpret their enforcement scope in this feature.

Blocking the app carrying the conversation can end the conversation before a
reply arrives. Explain that immediately before applying, persist the receipt
in Fence, and let the helper continue independently of agent/app exit. Do not
introduce a cancellation grace period just to deliver a chat acknowledgement.
Read-only status on return resolves an uncertain outcome without a new block.

## Additive enforcement contract

For every resource and instant:

`effective permission = calendar permission AND manual permission AND every active short-block permission`

For deny-only apps this is the union of all deny sets. For app allow sets,
intersect allow sets and then subtract denied apps. Terminal being allowed by
a short block cannot override a calendar ban on Terminal. Multiple short blocks
must preserve independent deadlines; expiry must not globally clear blocking.

Compose inside the daemon's single policy reconciliation path. Do not turn a
short block into a manual block that prevents scheduler progress. Recompute on
calendar boundaries, short-block expiry, recurring breaks, wake, and restart.
Recurring breaks affect only their existing recurring layer; they never pause
a short block. Preserve calendar metadata, deadlines, break balances, Protected
Hours and recurring timezone semantics.

Apply composition without a remove-all/reapply interval that exposes an app or
site still blocked by another layer. The current scheduler's deferred replacement
behavior means this is real enforcement work, not merely CLI plumbing.

Persist the accepted deadline and request identity in root-owned state. Count
sleep as elapsed duration; timezone changes must not change a twenty-minute
duration. Reuse the product's established clock-integrity policy after examining
it; do not claim resistance to deliberate clock changes merely from storing a
wall-clock deadline. On reboot, resume the remaining restriction or expire it
if its deadline has passed.

## Agent interface proposal

Add a narrow signed CLI interface backed by new helper capability/version
negotiation. Names and storage schema remain undecided; these are operations,
not commands that exist today:

- Resolve/preview installed app identities and the effective policy impact.
- Create an immutable short block with an idempotency key, target policy and
  duration. The helper derives owner and accepted times.
- Read request status/receipt: accepted start/end, persisted state, enforcement
  outcome, and constraints still imposed by other commitments.

Return distinct rejected, accepted-but-enforcement-unverified, and enforced
outcomes. An uncertain call is resolved using the same idempotency key; retry
must not restart the twenty-minute timer or create another commitment. Report
“enforced” only after relevant physical-layer checks.

Expose no short-block cancellation, schedule replacement, pause or helper-reset
operation in this surface. Validate additive composition in the helper, not in
skill prose. A cooperative agent skill should never invoke legacy remove/start,
edit root preferences, alter clocks, kill the daemon, or use debugging paths to
weaken an existing commitment.

The skill is guidance, not a security boundary against a fully privileged agent.
An agent with unrestricted administrator/root execution cannot be constrained
by this CLI alone; preventing that requires an execution-permission boundary
outside the skill. Do not describe “only Terminal” as preventing every possible
computer activity: Terminal can itself run CLI tools, including agent clients.

## “Only Terminal” implementation choice

Recommend a genuine temporary allow-only policy for interactive applications,
not a snapshot deny list of installed apps. A snapshot misses newly installed
or moved applications and does not express the user's intent.

Define app-enforcement scope separately from essential OS/session services;
that distinction does not exempt Terminal or any other user app. Do not add a
built-in allowed-app exception set or hardcode “except Terminal.” An allow-only
request keeps only apps explicitly chosen by the user, subject to every existing
restriction. Network access and command-line programs retain their independently
composed policies. If an existing commitment blocks Terminal, explain the
conflict rather than relaxing it.

This is additional app-enforcement scope. A deny-only first delivery can support
“block Codex” but must explicitly report “only Terminal” as unsupported until
allow-only enforcement is implemented.

## Proposed future skill outline (not installed)

Name: `fence-short-block`

Proposed app-first description: Create additional timed app restrictions on the
current Mac through Fence.

Advertise allow-only sessions only once implemented. Website short blocks are
an optional later scope extension, not required by the user's app examples or
by v1; advertise them only if implemented and verified.

Body should contain only:

1. Resolve the intended Mac/account, exact apps, and duration; explicit clear user
   requests authorize adding the restriction.
2. Check the installed CLI/helper's advertised short-block capabilities. Never
   substitute legacy start or recurring-template edits for an unsupported mode.
3. Explain caller-app termination where relevant; submit through the narrow
   interface with a stable request identity.
4. Query and report the receipt and enforcement result, including restrictions
   that continue after the short block. On uncertainty, query/retry the same
   request identity.
5. Never weaken existing commitments or attempt an alternate bypass path.

Only add exact CLI syntax after it exists and is verified. Before any actual
skill creation, follow skill-creator validation and the user-required fresh
low/light-reasoning review.

## Acceptance evidence needed before release

Behavior tests should cover Codex termination/relaunch, an upcoming calendar
block starting during a short block, expiry while a calendar block remains,
calendar expiry while the short block remains, overlapping independent short
blocks, recurring breaks, helper restart/sleep, and an uncertain create retry.
Tests must cover Terminal selected as a normal bundle deny target and a
short-block deny target, with no exemption in either path. Allow-only tests must
include launching a newly installed app, required OS/session services remaining
usable, Terminal allowed only when explicitly chosen and still denied by an
existing calendar restriction, and a second logged-in account remaining unaffected
by the new short block under the proposed owner-only scope. Verify on a real
signed helper; source or unit tests alone do not establish physical enforcement.

Discussion decisions: approve independent additive commitments; choose duration
bounds; choose whether allow-only ships alongside deny-only; settle OS/session
service scope without user-app exceptions, enforcement account scope, and whether
website short blocks belong in a later release. Storage/API schema approval and
implementation are subsequent work, not authorized by this proposal.
