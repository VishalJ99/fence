# PER-579: calendar selection and bundle editor

Parent: PER-444. Status: confirmed iPhone parity implemented by GPT-6.1 Sol
medium, independently reviewed by Astra high; 197 tests pass. Signed and
notarized 3.4.17/build659 is installed on the Mac mini and normal LaunchServices
launch succeeded. Installed helper upgrade remains pending normal menu-bar Repair and local
administrator authentication. Native Computer Use action snapshots were captured
on the Mac mini; performance capture is scoped but does not establish smoothness. No public release is authorized or implied. Short-block feature/skill
work remains design-only and awaits separate discussion.

## Confirmed interaction and protection contract

The Finder photo supplies the translucent selection-rectangle reference.
Select one sidebar bundle first, then Shift-click its calendar entries or
Shift-drag a rectangle over its entries. All-Up cannot select entries; changing
bundle clears selection. An unmodified empty-space drag creates an entry for
the selected bundle. Selection shares one snapped movement/resize delta,
bounded by the group; delete and pinch operate on the group. Undo is available in ordinary
uncommitted editing; active edits use Reset/Cancel and reject undo to avoid
stale state. Other
bundles' entries are dimmed and do not participate.

An explicit row Edit action opens a draft with visible Cancel and Save. New
bundles default to Block and can be created, edited and deleted during an
existing commitment until admitted by calendar Save. Save admits eligible
members into that same commitment without changing its authenticated owner,
generation or deadline. Block blocks contents inside its windows; Allow blocks
contents outside its windows. Neither is a whole-device app allowlist.
Nonempty Allow admission has a separate warning, including no-window Allow
bundles that become blocked all week. An unscheduled new Block bundle remains
unadmitted. An all-week-window Allow bundle can be protected while never blocking.

After admission, metadata/policy, deletion and content removals are locked;
content additions remain available through the daemon append path. Existing
Allow windows may shrink or disappear, without new Allow windows. Block edits
must preserve every previously blocked minute. Unadmitted bundles may freely
draft their first timetable. Group interactions grant no additional permissions.
Expiry permits End when otherwise eligible; it does not itself remove protection.

Protection cues follow membership, including allowed windows, breaks and an
expired-but-not-ended commitment. The list has a red outline and **In active
session** legend. The protected editor has a red lock warning: **Bundle is being
used in the current session. Modifications are restricted. Content can be
added.** Name/policy fade to 62%; unselected colours to 42%. New drafts retain
normal appearance. Selection has a separate cue. Calendar policy borders are
solid for Block and dashed for Allow, using bundle colour; a red calendar
border alone does not mean protection.

## Implementation and recovery boundary

Source implementation: `a0bbf98`; test expectation correction: `ceca81b`.
The daemon owns optional `protectedBundles` snapshots, including members with
zero blocking segments. Membership and calendar admission persist atomically;
metadata/policy are immutable, contents additive and per-bundle blocked coverage
monotonic. Unadmitted local bundles are excluded from enforcement projections.
Legacy persisted bundles without policy decode as Allow; legacy commitments
retain their previous enforcement and conservatively captured membership.
Helper protocol is 12. Status boundaries are half-open and include the next
week's same weekday. Detailed-editor labels and Shift-marquee hit testing follow
the same policy/selection rules.

Runtime refresh imports authoritative membership but does not reconstruct a
missing/stale local calendar after interrupted local persistence. Root validation
rejects weakening/stale saves; automatic calendar repair is not claimed.

## Verification and reproduction

On the Mac mini, Debug build-for-testing and all **197 XCTest tests** passed.
Tests cover policy inversion/boundaries, root persistence and monotonicity,
verified/failed admission, unchanged deadlines/runtime, protected versus draft
editing, and calendar/editor interaction rules. Tests use isolated root settings
and transport doubles, not live commitments. An internal copy of the built test
bundle avoids the external-volume test-runner access issue. Actual hardware
pinch and Shift-marquee remain unverified by the supported tool. Native action
snapshots confirm focused Shift-click selection, grouped movement/resize/deletion, draft
Save and protected editor restrictions in a synthetic in-memory fixture. A scoped
30-second Time Profiler capture completed; no render-latency or smoothness claim
is made. Fixture undo lacks the production delegate registration and is not proof
of production undo.

Build from `SelfControl.xcworkspace`, scheme `SelfControl`, with explicit
`-derivedDataPath /Users/dross/fence/build/DerivedData`, destination
`platform=macOS,arch=arm64`, `CODE_SIGNING_ALLOWED=NO`, and
`TMPDIR=/Volumes/MacMiniStorage/builds/fence/build/tmp`; use Debug
`build-for-testing` or Release `build`. Load the existing private Sentry env
silently for Release. The selected Xcode needs the inherited libc++ and Swift
compatibility-library settings already reviewed in the project. No dependencies
changed. Initial SSD cache access stalled before compilation, then recovered
after reconnection; no cache deletion or storage relocation was used.

Test reproduction: `ditto` the built `SelfControlTests.xctest` to the chat's
existing `work/internal-tests/`, then run `xcrun xctest` with
`DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks`
and `DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib`.
Set `LLVM_PROFILE_FILE` under chat `work/` to preserve tracked `default.profraw`.
Passing logs: chat `work/mac-parity-build-testfix2.log` and
`work/mac-parity-xctest-testfix2.log`.

## Mac mini installation checkpoint

Before installation, the old app reported 6.4.5/build645; this is a starting-state
observation, not proof of its ancestry. Exact app and private-state backup:
`build/DerivedData/PER-579-before-update/`; its `reproduction.txt` and
`backup-manifest.json` record integrity and state boundaries. All 193 regular
files of the installed old app matched the backup immediately before replacement.

Release arm64 build and Developer ID signing passed with the approved embedded
Direct Distribution profile (UUID `bb4d6dc8-cb4d-4303-9c5f-d06f3d1d997c`), team
`L5YX8CH3F5`. The signing keychain was re-locked and its locked state checked.
Private Apple notarization `3c3e7c1f-c1e1-476b-b770-55ed08ef9874` was Accepted;
stapling and validation passed. No release-specific Sentry symbols were uploaded.

Installed by copying the prepared app into `/Users/dross/Applications/Fence.app`,
removing superseded app-bundle files while preserving the verified backup.
Installed version/build, main/helper hashes, strict deep signature, staple and
Gatekeeper acceptance (`Notarized Developer ID`) were checked. Sentry DSN is
configured; its value was not logged. Main executable SHA-256:
`91eb291ac8e91ed05ec33aa1fbe8bc226dd1330b1c8a4a64528aad2d09aabb14`.
Embedded helper SHA-256:
`ddd59a30a6d4674b17b6caf1bef1248e88a869c46ef978a0c87ab9d5cf9d415d`.

The running `/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold` remains the
old binary, SHA-256
`c61eb91a4c285cba41117be713d0797e83b6eaa7122b2fb2e6c1a2e68ea6a6e0`.
File installation made no helper replacement, live setting/calendar mutation or
real commitment. A subsequent normal LaunchServices `open` of the exact installed
app succeeded; PID 7920 remained alive beyond ten seconds and was left running.
No GUI content or authentication prompt was inspected/clicked. The live helper
still had its old PID/hash after launch; launch alone is not upgrade proof.
Next: recover trusted Computer Use access, inspect the running installed app,
complete its normal helper update/administrator authentication if requested,
then verify helper protocol/hash and preserved state before calling the local
deployment complete. Do not create a real commitment for verification.

Computer Use was restored and actual native state queries and interactions
succeeded. Production Add Bundle defaulted to Block and Cancel returned to the
empty calendar. No real bundle or commitment was saved. The status-menu Repair
action is not exposed in the supported app-scoped accessibility tree, and closing
the main window produced a state-query timeout. Commit is not a safe upgrade probe:
the manager call follows its final commitment confirmation. Local helper update
therefore awaits the user choosing Repair Fence Permissions and authenticating. The test-only native fixture uses
production views and synthetic in-memory data and proves neither daemon
admission nor persistence. Evidence is under the chat's existing `work/`:
`mac-parity-release-*`, `mac-parity-private-*`, and
`mac-parity-installed-{proof.json,signature.log,staple.log,gatekeeper.log,launch.txt,launch-system.log}`.

## Reference authority and limits

As checked on 2026-10-20, GitHub master and the mini's starting commit were
`fc53fea`. After remote-ref refresh only, the dirty MacBook reference checkout
was 59 commits behind and three ahead (`4592bef`, `3a299bb`, `483055b`), not a
newer shared mainline. No MacBook worktree files were changed or merged.

App Store Connect confirmed Fence iOS 1.0/build25 valid and the sole Friends
build. Candidate source is `97d984307cb0d1a51bcd7881e4055b7c893d6722`, six minutes
before upload on 2026-08-28. Archive-to-commit linkage remains unproven; the
physical iPhone was unavailable. Flow and visual descriptions above are source
inferences accepted by the user, not a claimed physical TestFlight test.
Native evidence: chat `outputs/per579-cua/index.html`, `reviewed-steps.json`,
`verification.md`, and `reproduction.txt`. Raw trace is private under chat
`work/private-per579-trace/`; it embeds process environment and is excluded from
sharing. Initial ambiguous-coordinate snapshots are not counted as proof. A fresh Draft
resize test selected Monday/Tuesday09:00–12:00; dragging the Monday bottom handle
from[395,360]to[395,378] visibly extended both entries to13:00 with unchanged
09:00 starts (`12-resize-before.png` / `13-resize-after.png`).

Relevant candidate anchors in `Brake/BrockerView.swift`: protection/list `16014`,
editor `16175`, policy border `5888`, calendar dimming `7790`, active rules
`9382`, warning `25398`, and create/admit/update paths
`20926`, `20481`, `10093`, `8770`, `19948`; strengthening rules also live in
`FenceActiveEditPolicy.swift:385-408`. Compared current iOS function bodies were
unchanged for these flows/cues; later content-removal changes do not establish
build25 appearance.

## Post-authentication verification

The user reported Repair complete. Read-only verification still found old helper
PID321/hashc61eb91a4c285cba41117be713d0797e83b6eaa7122b2fb2e6c1a2e68ea6a6e0.
A normal restart of only the exact installed app restored the main window,
version3.4.17/build659 PID13509. Its fresh compatibility handshake logged
`Retaining legacy recurring daemon until a protected user action (protocol=6)`;
protocol12 remains required. No matching installer outcome was established in
the preceding app logs. Do not infer failed authentication or a source installer
bug from this gap; the actual Repair destination/result needs clarification.

The private root settings and LaunchDaemon plist remain byte-identical to the
pre-update backup. Effective SelfControl defaults and Fence recurring schedule
and migration values are unchanged. Changed Fence preference keys are limited to
telemetry consent generation, preferences-window/pane state, break-credit day
rollover and Sparkle check/profile timestamps. No real commitment was created.
Sanitized evidence is chat`outputs/per579-cua/helper-status.json`. Private artifact
route is`https://drosss-mac-mini.tail8111ef.ts.net/artifacts/per579-fence-mac-qa/`,
staged under`/Users/dross/.local/share/codex-artifacts/per579-fence-mac-qa/`. Parent
verified HTTPS index on Mac mini and MacBook; physical iPhone not tested.

## Repair action fix after the reported no-op

The user clarified that choosing Repair produced neither a result nor an
administrator prompt. Source diagnosis found a nil callback on ordinary cold
launch without a commitment: AppController only assigned status-menu callbacks
inside active-block/committed branches. The menu item itself had the correct
target and selector, but repairPermissionsClicked silently skipped its nil
onRepairPermissions callback.

All five existing callback bodies now register once, unconditionally in
applicationDidFinishLaunching. Duplicate state-conditional wiring was removed;
visibility, enforcement guards, helper upgrade logic and authorization are
unchanged. Astra high independently reviewed the exact move and early singleton
initialization and found no actionable issue. Debug build-for-testing succeeded;
the unchanged isolated 197-test suite passed again. AppController is not linked
into that unit-test target, so those tests do not prove the callback regression;
normal Repair on the fixed installed app remains the final runtime proof.

The authorized local fix keeps marketing version3.4.17 and advances all existing
project build configurations to660, distinguishing it from installed659. No
public release/tag/appcast change is authorized. Historical gesture screenshots
and profile capture remain build659 evidence; they must not be relabeled660.
Private Release660 preparation/signing/notarization and installation follow the
existing path; capture its new embedded helper hash before normal authenticated
Repair. No direct root helper replacement or enforcement reset is permitted.

## Fixed private build660 installation

Source884e4e3 Release build passed. Developer ID signing and strict deep signature
verification passed; the release keychain was checked locked. Private Apple
notarization5e81b693-9de4-4d0d-87f6-2b58ca4ba745 was Accepted. Staple validation
and Gatekeeper accepted the installed app as Notarized Developer ID.

Before replacement, all195 regular files of installed659 matched a preserved
Fence-build659.app under the existing pre-update backup directory. Original645
app/helper/private-state backups remain intact. Installed660 runs from the exact
/Users/dross/Applications/Fence.app path as PID32115. Main executable SHA-256 is
cf2392b249209f3e657828c9b4c6b31b729958b9b1e11571cfbeab459f913848.
New embedded helper SHA-256 is
c2668e8afcd6249216114b30a84032907b474e545b3b93fd166ed6da8ff47c52.
Do not use the earlier659 helper hash as the660 target.

The live helper remains old PID321/protocol6 until normal authenticated Repair.
The user was asked to repeat Repair only after the nil-callback fix was installed
and explained. No result from that new action has arrived yet. No direct helper
copy/removal or real commitment was used. Signed app startup logs confirm the
live protocol6 handshake and deliberate retention until a protected action.
Native660 screenshot is pending: both unchanged QA and new production app had
cgWindowNotFound. Display wake reported a console-session lock flag despite
IOConsoleLocked=No; supported Computer Use could inspect loginwindow wallpaper
but no visible login controls. No app restart was attempted during pending auth.
The build659 gesture/profile evidence remains unchanged and explicitly scoped.

Evidence is chatwork/mac-repair-{build-test,xctest,release-build660,sign660,
notary660,staple660,installed660-*} and public-artifact-safe helper-status.json.
No release-specific Sentry upload/public tag/appcast/GitHub release occurred.
Remote source push remains blocked by existing HTTPS credentials; the parent's
read-only existing SSH test also found no accepted key, without credential edits.
