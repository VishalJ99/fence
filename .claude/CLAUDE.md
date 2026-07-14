# SelfControl - Agent Instructions

> **CRITICAL:** This file MUST be read by any AI agent before making changes to this codebase.

---

## Project Overview

**SelfControl** is a macOS app that blocks websites/network resources for a set time. The block cannot be disabled until the timer expires—even rebooting won't help. Written in Objective-C with a privileged daemon architecture.

**Current Focus:** Root-owned V2 schedule timing in `selfcontrold` (PER-383),
with V1 LaunchAgents retained only for bounded rollback/drain compatibility.

**Source plan:** `/Users/vishaljain/.claude/plans/can-you-help-me-unified-dove.md`
(historical MacBook input; re-check claims against this canonical checkout).

---

## Documentation Map

```
📁 selfcontrol/
├── 📄 SYSTEM_ARCHITECTURE.md      ← START HERE: Complete architecture
│   ├── Component deep dives
│   ├── Mermaid flow diagrams
│   ├── Security model
│   └── Extension points
│
├── 📁 docs/
│   ├── 📄 INDEX.md                ← Quick navigation & module map
│   ├── 📄 BLOCKING_MECHANISM.md   ← How blocking works + app blocking design
│   ├── 📄 SCHEDULE_JOB_LIFECYCLE.md ← V2 root scheduler + V1 drain path
│   ├── 📄 DAEMON_LIFECYCLE.md     ← Startup, exact boundary timer, recovery
│   ├── 📄 TELEMETRY.md            ← Typed privacy and scheduler diagnostics
│   ├── 📄 dictionary.md           ← Domain terminology index
│   └── 📁 dictionary/             ← Full term definitions
│
└── 📁 .claude/
    └── 📄 CLAUDE.md               ← You are here
```

---

## Shared Vocabulary Protocol

### Dictionary Location
- **Index:** `docs/dictionary.md` — Load this at session start
- **Full entries:** `docs/dictionary/[term].md` — Search on-demand

### Key Terms (Quick Reference)

| Term | Definition |
|------|------------|
| **Editor** | UI sheet for defining allowed windows per bundle/day |
| **Allowed Window** | User-defined time range when bundle is NOT blocked |
| **Block Window** | Computed inverse - when blocking IS active |
| **Segment** | Time slice with consistent set of active bundles |
| **Merged Blocklist** | Combined entries from all active bundles in a segment |
| **Committed State** | Schedule locked after user confirms |
| **Pre-Authorized Schedule** | Segment registered with daemon (password-free execution) |
| **Root-Owned Schedule** | Immutable root absolute-week envelope + zero or more V2 segments timed by `selfcontrold`; no user LaunchAgent |
| **Bundle** | Named group of websites/apps |
| **Entry** | Single blocked item (domain or app bundle ID) |

### How to Reference

1. Load `docs/dictionary.md` (the index) at session start
2. When you encounter a term from the index, read its full entry in `docs/dictionary/`
3. Use the dictionary definition—NOT your general knowledge
4. If a term is missing, flag it and ask for clarification

**Example workflow:**
```
User: "When the user is in a committed state, disable the editor"

Agent thinks:
- "committed state" → read docs/dictionary/committed-state.md
- "editor" → read docs/dictionary/editor.md
- Now I understand: disable SCDayScheduleEditorController when isCommitted=YES
```

### When Modifying Code

If your changes affect files listed in any dictionary term's "Code Locations":
1. Re-read that term's full entry
2. Verify your changes align with the defined behavior
3. Update the dictionary entry if behavior has changed

### When You Encounter an Undefined Term

If a term seems domain-specific but isn't in the dictionary:
1. Flag it in your response: "⚠️ Term '[X]' not found in dictionary"
2. Ask the user for a definition
3. Suggest adding it to the dictionary using `/define-terms`

---

## Agent Responsibilities

### Before Making Changes

1. **Read the relevant documentation:**
   - For architecture questions → `SYSTEM_ARCHITECTURE.md`
   - For blocking logic → `docs/BLOCKING_MECHANISM.md`
   - For quick file lookup → `docs/INDEX.md`

2. **Understand the component you're modifying:**
   - App layer: `AppController.m`, `TimerWindowController.m`
   - Daemon layer: `Daemon/SCDaemon*.m`, including
     `Daemon/SCDaemonScheduler.m` for schedule timing/arbitration
   - Blocking layer: `Block Management/*.m`
   - Common utilities: `Common/*.m`

### After Making Changes

**⚠️ MANDATORY:** Update documentation when you:

| Change Type | Update These Files |
|-------------|--------------------|
| New feature/component | `SYSTEM_ARCHITECTURE.md` (add section) |
| Modified blocking logic | `docs/BLOCKING_MECHANISM.md` |
| New files created | `docs/INDEX.md` (module map) |
| API/XPC changes | `SYSTEM_ARCHITECTURE.md` Section 9 |
| New settings | `SYSTEM_ARCHITECTURE.md` Section 9.2 |

### Documentation Standards

- Keep Mermaid diagrams in sync with code
- Update "Key Files" tables when adding files
- Add new error codes to error code table
- Update file line counts if significantly changed. Use current `wc -l` output
  at handoff; do not preserve historical approximations for a newly added or
  substantially rewritten component such as `SCDaemonScheduler`.

---

## Key Architecture Points

```
┌─────────────────────────────────────────────────────────────┐
│  SelfControl.app (User)  ←── XPC ──→  selfcontrold (Root)  │
│         │                                    │              │
│         └── UI/Settings                      └── Blocking   │
│                                                  ├── /etc/hosts
│                                                  └── pfctl
└─────────────────────────────────────────────────────────────┘
```

**Critical Concepts:**
1. **Triple-layer blocking** - DNS redirect + packet filter + app-process enforcement
2. **Privilege separation** - App cannot modify system files
3. **Continuous verification** - 1-second checkup timer
4. **Tamper resistance** - Settings in `/usr/local/etc/`
5. **Root schedule authority** - V2 owner/week batches are atomic and
   reconciled by `SCDaemonScheduler` at absolute boundaries and recovery
   triggers
6. **Compatibility boundary** - V1 LaunchAgents/CLI are rollback/drain only;
   the current one-minute inter-segment gap remains until staged physical
   replacement exists
7. **Commitment immutability** - Root envelopes include zero-segment weeks;
   exact same-batch retries with matching identity/content are idempotent, while any different
   unexpired absolute overlap (including live V1) is rejected regardless of
   local week-key/defaults drift
8. **Bidirectional compatibility guard** - V2 admission rejects overlapping
   live V1 records, and legacy V1 registration rejects an overlapping
   unexpired V2 envelope
9. **Destructive-test boundary** - Release helpers reject bulk approved-schedule
   clearing; DEBUG clearing removes both records and commitment envelopes

---

## Historical Major Feature: App Blocking - IMPLEMENTED

**Status:** Implemented and ready for testing

**What was added:**

1. **App Blocking Engine** (`Block Management/AppBlocker.h/m`)
   - Polls running apps every 500ms
   - Kills apps matching blocked bundle IDs
   - Thread-safe with NSLock

2. **Entry Format Extension** (`Block Management/SCBlockEntry.h/m`)
   - Added `appBundleID` property
   - Parses `app:com.bundle.id` format
   - `isAppEntry` method to check entry type

3. **BlockManager Integration** (`Block Management/BlockManager.h/m`)
   - Routes app entries to AppBlocker
   - Starts/stops monitoring in finalizeBlock/clearBlock

4. **Debug Mode Safety** (`Common/SCDebugUtilities.h/m`)
   - "Debug > Disable All Blocking" menu (DEBUG builds only)
   - `#ifdef DEBUG` wrapping - compiled out of release builds
   - Visual indicator in window title

5. **UI for Adding Apps** (`DomainListWindowController.m`)
   - `addAppToBlocklist:` action opens app picker
   - App entries shown in purple with app name

6. **Startup Safety Check** (`Common/SCStartupSafetyCheck.h/m`, `SCSafetyCheckWindowController.h/m`)
   - Triggers on macOS or app version change (ALL builds - DEBUG and RELEASE)
   - Phase 1: 30-second test block (example.com + Calculator), verifies add/remove works
   - Phase 2: Tests emergency.sh can clear an active block
   - Prevents users from getting stuck in blocks on incompatible macOS versions
   - See `docs/BLOCK_SAFETY_ANALYSIS.md` for full robustness analysis

**Entry Format:**
```
app:com.apple.Terminal     - Block Terminal
app:com.cursor.Cursor      - Block Cursor
facebook.com               - Existing website block
```

**Debug Mode:**
- Only in DEBUG builds
- Menu: Debug > Disable All Blocking
- Disables ALL blocking (apps + websites)

---

## Quick Reference

### Important Paths
| Path | Purpose |
|------|---------|
| `/etc/hosts` | DNS redirects |
| `/etc/pf.anchors/org.eyebeam` | Firewall rules |
| `/usr/local/etc/.{hash}.plist` | Settings (root only) |

### Key Classes
| Class | Purpose |
|-------|---------|
| `BlockManager` | Orchestrates all blocking |
| `HostFileBlocker` | Modifies /etc/hosts |
| `PacketFilter` | Creates PF rules |
| `SCDaemonBlockMethods` | Daemon block operations |
| `SCDaemonScheduler` | V2/V1 desired-state selection and schedule timers |
| `SCBlockEntry` | Block entry data model |

### Build & Run

> **IMPORTANT:** This project uses CocoaPods. You MUST use the **workspace**, not the project file.

```bash
# First time setup
pod install

# Debug build (CLI)
xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl -configuration Debug

# Release build (CLI)
xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl -configuration Release \
    -derivedDataPath build/DerivedData -arch arm64

# Full release with signing, notarization, and DMG
./scripts/build-release.sh 1.0

# Run (requires signing for SMJobBless)
open build/Release/SelfControl.app
```

**Common mistake:** Using `-project SelfControl.xcodeproj` will fail with linker errors like `library 'Pods-SCKillerHelper' not found`. Always use `-workspace SelfControl.xcworkspace`.

---

## Code Style

- **Language:** Objective-C
- **Naming:** `camelCase` for methods/variables, `PascalCase` for classes
- **Comments:** Only where logic isn't self-evident
- **Threading:** Use `NSLock` for shared state, `dispatch_async` for background work

---

## Testing Checklist

Before submitting changes:
- [ ] Block starts correctly
- [ ] Block persists through reboot
- [ ] Timer displays correctly
- [ ] Block ends at correct time
- [ ] V2 commit writes one owner/week root batch and creates no LaunchAgent
- [ ] Zero-segment V2 commit still stores a root commitment envelope
- [ ] Exact identity retry is idempotent; different unexpired V2/V1 overlap is rejected across timezone week-key shifts
- [ ] Legacy V1 registration is also rejected across an unexpired overlapping V2 envelope
- [ ] Release builds reject bulk approved-schedule clearing; DEBUG clears both root maps
- [ ] Startup/wake/clock/timezone reconciliation selects the correct half-open segment
- [ ] Manual/test and active-to-active schedule conflicts defer without remove-then-add
- [ ] Active matching verifies owner/source, commitment/generation, mode, policy revision, and content
- [ ] Strictifying an active scheduled record physically applies/verifies additions under the daemon mutation lock before persisting the stricter future record
- [ ] V1 jobs remain readable/strictifiable only as compatibility state
- [ ] No memory leaks (Instruments)
- [ ] Daemon terminates when idle

---

*Last updated: July 2026 (PER-383)*
*Update this file when making significant architectural changes*
