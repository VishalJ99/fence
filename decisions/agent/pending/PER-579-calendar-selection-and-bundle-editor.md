# PER-579: calendar selection and bundle editor

Status: initial calendar/editor slice reviewed and build/test verified.
User confirmed iPhone parity, visual cues and Mac mini installation; expanded
implementation is in progress with GPT-6.1 Sol medium and Astra high review.
Parent: PER-444.

## Calendar interaction

The supplied Finder photo is a visual reference for a translucent drag-selection
rectangle. The user subsequently changed and clarified the interaction:
select one bundle first, then Shift-click its calendar entries or Shift-drag
a rectangle to select multiple entries belonging only to that bundle. All-Up
does not select entries; changing bundle clears the old selection. Unmodified
empty-space dragging retains entry creation for the selected bundle.
Selected windows share one snapped movement or resize delta, bounded by the
whole selection. Deletion and undo operate on the group. Pinch changes selected
durations together. Bundle-focused empty-space dragging retains window creation.

Entries follow their bundle's Block or Allow policy. Existing protected members
remain read-only outside the active edit flow; active drafts may only strengthen
their blocked coverage. New unadmitted bundles may freely draft their first
timetable. Group interaction does not grant new edit permissions.

## Bundle editing

Use the current iOS app as a flow reference, while preserving Mac calendar focus:
an explicit row Edit action opens a draft editor with visible Cancel and Save.
Protected entries remain immutable; unsaved additions can be removed before Save.
Committed additions continue through the existing verified daemon append path.

The user authorized creation during a recurring commitment and the corresponding
membership/policy model changes by confirming exact iPhone parity. Simply
allowing local creation is unsafe in the original Mac model: missing
schedules mean continuously blocked in Mac logic, and later compilation includes
all local bundles. Mac has no equivalent of iOS's protected-bundle snapshot.
The new implementation must distinguish unadmitted drafts from protected
commitment members and preserve existing commitments during the upgrade.

## Verification boundaries

The Mac mini's installed `/Users/dross/Applications/Fence.app` initially reports
6.4.5/build645; source `fc53fea` reports 3.4.16/build658. This proves a mismatch,
not the installed app's exact ancestry or observed bundle behavior.

Implementation is assigned to separate Astra medium agents; independent code
review is assigned to Astra high. Tests, build and deployment results belong in
the PER-579 closeout comment once verified. No public release is implied.

On the Mac mini, the final app build-for-testing and all 186 XCTest tests passed.
The normal Xcode runner waited on external-volume TCC consent, so execution used
an isolated internal copy of the built test bundle. The only initial failure was
a test body-drag coordinate inside an active resize hit zone; the fixture was
corrected without changing enforcement. Actual hardware pinch is unverified;
event hit-testing and AppKit responder forwarding were checked.

Release arm64 compilation and Developer ID signing passed; the embedded profile
is present, strict deep signature verification passed, and the signing keychain
was re-locked. The prepared app remains 3.4.16/build658 under the established
build/DerivedData path. It has not been launched, installed, notarized or
published. Installation waits for confirmation of the expanded bundle flow.

Building against the current Sentry pod required explicit inherited libc++
linkage and the selected Xcode's default Swift compatibility-library directory
for app/test Debug and Release configurations. Astra high reviewed those
settings. No dependencies were changed. Reproduction: use the AGENTS.md build
commands with `-derivedDataPath /Users/dross/fence/build/DerivedData`; the
PER-579 Linear comment records isolated test execution and private-signing
evidence locations. No release symbols were uploaded.

The separate short-block proposal remains pending user discussion; no related
feature or discoverable skill is installed by this change.

## Follow-up authority checks

Live GitHub master and the mini's starting commit both resolve to `fc53fea`.
After refreshing only remote refs on the MacBook, its dirty
`/Users/vishaljain/selfcontrol` master is 59 commits behind and 3 commits ahead of
GitHub: `4592bef`, `3a299bb`, `483055b`. These are older divergent changes, not a
newer shared mainline. No MacBook worktree files were changed or merged.

Live App Store Connect confirms Fence iOS 1.0/build25 is valid and the sole build
in Friends. Candidate source is `97d984307cb0d1a51bcd7881e4055b7c893d6722`, the
build-number commit six minutes before upload on 2026-08-28. Archive-to-commit
linkage is unproven; the physical iPhone was unavailable to devicectl. Therefore
the following is source-inferred flow, not a claimed physical TestFlight test:

- A new bundle can be created while committed and remains editable/deletable
  until admitted by calendar Save.
- Calendar Save admits its initial timetable into the existing commitment
  without restarting or extending the deadline. After admission, metadata,
  deletion and removals are protected; content additions remain allowed.
- Block policy blocks contents inside windows. Allow policy blocks contents
  outside windows. Neither is a whole-device app allowlist.
- Admission includes a warning for nonempty Allow bundles, including those with
  no windows that become blocked all week. Subsequent Allow windows can shrink
  or disappear but cannot be newly added. Expiry alone does not end protection.

Relevant candidate source: `Brake/BrockerView.swift` lines16014,20926,20481,
10093,8770,19948 and `FenceActiveEditPolicy.swift` lines385-408. The user requested
an ELI5 explanation to confirm before copying this behavior to Mac; no membership
schema or daemon changes have been implemented pending that confirmation.

### iPhone visual meaning and Mac parity proposal

Read-only source comparison on 2026-10-20; Mac checkout clean at `c01aa18`.
The same TestFlight/source-linkage caveat above applies. At candidate `97d9843`:

- Bundle-list red outline (red at 0.62 opacity, 1.5pt) and the legend
  **In active session** mean membership in the protected commitment snapshot,
  not "blocking right now." The card itself is not globally dimmed. A new
  unadmitted bundle has no red outline and remains editable.
- A protected bundle's editor shows a red lock icon, red text, faint red
  background and red outline: **Bundle is being used in the current session.
  Modifications are restricted. Content can be added.**
- Name is disabled and rendered at 0.62 opacity. Colour choices are disabled;
  unselected colours fade to 0.42 while the selected colour remains full
  strength. The policy section fades to 0.62 and tapping it explains that the
  policy cannot change. Delete is muted and tapping it explains the restriction.
  Apps & Websites remains available for additions. Save and Cancel remain
  available; protected content cannot be removed.
- These membership cues persist while the bundle is temporarily allowed by its
  timetable, during breaks, and after commitment expiry until explicitly ended.
  They are not a live blocking indicator.
- Calendar dimming has a different meaning: selecting one bundle fades other
  bundles' entries to 0.44 and disables their hit testing. "Active" in calendar
  accessibility text means selected/not dimmed, not currently blocking.
  Calendar borders encode policy: Block is solid; Allow is dashed. Their colour
  comes from the bundle, so a red calendar outline is not by itself a lock cue.
- Active calendar editing says **Stricter edits only**. Newly created Allow
  bundles have a notice that they join on Save and, without Allow entries, are
  blocked all day; admission has its separate red warning review.

Candidate source anchors in `Brake/BrockerView.swift`: bundle list `16014`,
editor `16175`, policy border `5888`, calendar dimming `7790`, active rules
`9382`, and warning banner `25398`. Exact function-body comparison against
current iOS HEAD found no change in bundle create/update/delete, protection
membership, active-calendar validation/admission, admission warning routing,
bundle-list rendering or lock-banner rendering. Later HEAD changes exist,
including content-removal controls; they are not evidence of build25 UI.

Mac `c01aa18` currently fades committed sidebar rows to 0.6 and uses their
outline for selection/hover, without the iPhone per-bundle red membership cue.
Its editor disables name/delete, fades the whole colour picker to 0.45 and shows
secondary-colour explanatory text. Sidebar creation remains disabled whenever
committed. These are source findings, not a new deployment.

Proposed parity: establish per-bundle protected membership first, then drive
the red list outline/legend and editor warning/disabled states from that same
membership. Keep new unadmitted bundles normal and editable. Preserve a
separate selection cue in the Mac sidebar/calendar; never infer membership
from selection, current blocking or timer expiry. Match the iPhone's visible
reason for restrictions rather than dimming every bundle indiscriminately.
This study implements no membership schema, visual changes or deployment.
The user has now confirmed this flow and these cues. Implementation and Mac mini
installation are authorized; short-block feature/skill work remains design-only.

## Confirmed implementation checkpoint

GPT-6.1 Sol medium implemented the confirmed flow; Astra high independently
reviewed it and the subsequent fixes. New bundles default to Block, matching
the iPhone source; persisted legacy bundles without a policy decode as Allow.
The daemon owns optional `protectedBundles` snapshots, including members with
zero blocking segments. Admission updates membership and calendar together,
preserving authenticated owner, generation and deadline. Metadata/policy stays
immutable after admission, contents are additive and blocked coverage cannot
decrease. Unadmitted local bundles are excluded from enforcement projections.
The helper protocol is now 12; app version/build is 3.4.17/659.

Review fixes include half-open status boundaries, searching the next week's
same weekday, policy-aware detailed editor labels, and Shift-marquee starting
over either selected or unselected entries. The detailed editor was added to
the test target for its new regression test.

The new implementation has **not yet compiled or executed its tests**. The
earlier 186 passing tests apply to the initial slice, not this expanded change.
The new Xcode attempt stalled before compilation while opening the SSD SwiftPM
package cache. Bounded diagnostics found hanging access checks on cache and
DerivedData paths; free space was ample. The owned stalled build was stopped.
No cache deletion, storage relocation or symlink changes were made.

The installed Computer Use connection lacks its trusted Sky service. A reviewed
two-line configuration correction adds the official Sky service and app path,
preserving browser and approval settings. The app-managed `node_repl` MCP server
must reconnect; an actual state query remains unverified. The test-only native
fixture uses production views and synthetic in-memory data, with no admission,
daemon or persistence proof implied. No new app has been installed or launched.
The old prepared build658 is stale and must not be installed for this change.

Recovery limit: runtime imports authoritative membership but does not rebuild a
missing/stale local calendar after interrupted local persistence. Root validation
rejects weakening/stale saves; automatic calendar repair is not claimed.
