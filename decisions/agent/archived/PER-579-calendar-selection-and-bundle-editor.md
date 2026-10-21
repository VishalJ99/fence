# PER-579: calendar selection and bundle editor

Parent: PER-444. Status: implementation and authorized Mac mini local deployment
complete; archived at closeout. Source884e4e3 is installed as private
3.4.17/build660. Astra high reviewed the changes;197 tests passed. Actual signed
app compatibility and consistency handshakes verified protocol12/divergence none.
No public release occurred. Physical pinch/Shift-marquee and animation smoothness
remain unverified. Short-block feature/skill remains a separate pending design.

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

## Final Mac mini deployment evidence

Installed `/Users/dross/Applications/Fence.app` is private3.4.17/build660 from
source884e4e3. Developer ID strict deep signature, matching approved embedded
Direct Distribution profile, private notarization Accepted
`5e81b693-9de4-4d0d-87f6-2b58ca4ba745`, staple and Gatekeeper passed. The signing
keychain was checked locked. No Sentry symbol/public release upload was made.
Main executable SHA-256:
`cf2392b249209f3e657828c9b4c6b31b729958b9b1e11571cfbeab459f913848`.

A reported Repair no-op exposed a nil callback on cold launch without a
commitment: old wiring only ran in active/committed branches. Source884e4e3
registers the five unchanged weak-captured callbacks once during startup and
removes duplicate conditional wiring. Astra high independently reviewed the
exact move. No helper authorization/enforcement logic changed.197 existing tests
passed again, but AppController is outside that unit target. Actual user Repair
on fixed660 is the final regression proof: normal app log at15:10:22 reported
`Daemon installed successfully without pre-removal`.

The installed and embedded helper hashes match exactly:
`c2668e8afcd6249216114b30a84032907b474e545b3b93fd166ed6da8ff47c52`.
Installed helper signature passed; launchctl reports running PID36790 at
`/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold`. After a normal app-only
restart, exact installed app PID37601 logged at15:11:28:
`Daemon compatible (protocol=12, build=<private>, marketing=<private>)` and
`Consistency snapshot complete (protocol=12 divergence=none)`.

Root settings and LaunchDaemon plist remain byte-identical to the pre-update
backup. Effective SelfControl defaults and Fence recurring schedules/migration
values are unchanged. Fence preference changes are only telemetry consent
generation, preferences-window/pane state, break-credit reset day and Sparkle
check/profile timestamps. No real commitment or persisted test bundle was
created, and no helper was directly copied/stopped or enforcement reset.

Exact original645 app/helper/private-state backup remains under
`build/DerivedData/PER-579-before-update/`. Before660 replacement, all195 regular
files of659 matched the additional `Fence-build659.app` backup there. Adjacent
manifest/reproduction records retain the recovery evidence.

Historical gesture snapshots and scoped30-second Time Profiler capture are659
production-view/synthetic-fixture evidence. Native660 captures14–16 verify Block
default/Cancel;17 verifies the post-upgrade empty calendar/no active schedule and
disabled Commit. The fixture proves neither live admission nor persistence.
Physical pinch/Shift-marquee and animation smoothness are not claimed. Raw trace
contains process environment and stays private under chat
`work/private-per579-trace/`; it is excluded from the shared artifact.

Evidence: chat`work/mac-repair-*`, `outputs/per579-cua/helper-status.json`,
`verification.md`, `reproduction.txt`, `reviewed-steps.json` and scoped PNGs.
Private cross-device route:
`https://drosss-mac-mini.tail8111ef.ts.net/artifacts/per579-fence-mac-qa/`, staged at
`/Users/dross/.local/share/codex-artifacts/per579-fence-mac-qa/`. Parent verified
HTTPS on Mac mini and MacBook; physical iPhone was not tested.

Remote feature-branch push remains blocked by existing HTTPS credentials; the
parent's existing SSH check found no accepted key. No credentials were changed.
This does not block the authorized local installation; no tag/appcast/public
release was requested.

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

