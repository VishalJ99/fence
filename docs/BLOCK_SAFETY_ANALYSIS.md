# Block Safety & Robustness Analysis

> **Purpose:** Technical analysis of block scheduling robustness, stuck-block risks, and safety mechanisms.
>
> **Last Updated:** July 2026 (PER-383)

---

## Executive Summary

Fence's blocking system is designed to be **tamper-resistant** but also **safe** - users should never get permanently stuck in a block they can't escape. This document analyzes:

1. How robust is the scheduling system against various failure modes?
2. What scenarios could cause a "stuck block"?
3. What safety mechanisms exist to prevent/recover from stuck states?

**Key Finding:** The V2 scheduler removes user LaunchAgents, a CLI path, and
per-commit daemon reinstall from the authority chain for future blocks. Root
store persistence plus wall-clock recomputation now survives logout, reboot,
wake, and Background Items changes. The primary stuck-block risk remains a
future macOS restriction on low-level apply/teardown operations
(`/etc/hosts`, `pfctl`, or process termination).

---

## Table of Contents

1. [Schedule Commitment Architecture](#1-schedule-commitment-architecture)
2. [System State Transitions](#2-system-state-transitions)
3. [Tamper Resistance Analysis](#3-tamper-resistance-analysis)
4. [Stuck Block Scenarios](#4-stuck-block-scenarios)
5. [Safety Check System](#5-safety-check-system)
6. [macOS Compatibility Risks](#6-macos-compatibility-risks)
7. [Emergency Recovery](#7-emergency-recovery)

---

## 1. Schedule Commitment Architecture

### Data Flow

```
User clicks "Commit to Week"
        │
        ▼
┌──────────────────────────────────────────────────────────────┐
│ SCScheduleManager.commitToWeekWithOffset:                    │
│                                                              │
│  1. Calculate zero or more segments + absolute-week envelope │
│  2. Verify daemon protocol 5 + root-scheduler capabilities   │
│  3. Send one authenticated owner/absolute-week batch         │
│  4. Reject unexpired overlap or persist envelope + records   │
│  5. Store commitmentEndDate + local V2 manifest              │
└──────────────────────────────────────────────────────────────┘
        │
        ▼ (at scheduled time)
┌──────────────────────────────────────────────────────────────┐
│ selfcontrold recomputes desired state at an absolute boundary│
│        │                                                     │
│        ▼                                                     │
│ Daemon selects validated root record (NO PASSWORD)           │
│        │                                                     │
│        ▼                                                     │
│ Block applied (hosts + PF + app blocking)                    │
└──────────────────────────────────────────────────────────────┘
```

### Key Data Locations

| Data | Location | Owner | Survives Reboot |
|------|----------|-------|-----------------|
| Commitment state | `NSUserDefaults` (SCWeekCommitment_*) | User | Yes |
| V2 local mapping manifest | `NSUserDefaults` (SCScheduleManifest_*) | User | Yes |
| Immutable V2 commitment envelope | `ApprovedScheduleCommitments` in root settings | Root | Yes |
| ApprovedSchedules | `/usr/local/etc/.{hash}.plist` | Root | Yes |
| V1 scheduled jobs (drain only) | `~/Library/LaunchAgents/` | User | Yes |
| Block rules | `/etc/hosts`, `/etc/pf.anchors/` | Root | Yes |

### Key Files

| File | Purpose |
|------|---------|
| `Block Management/SCScheduleManager.m` | Commitment logic, segment calculation |
| `Common/SCXPCClient.m` | Root-scheduler capability gate and batch call |
| `Daemon/SCDaemonXPC.m` | Absolute-overlap/idempotency admission and atomic envelope + record persistence |
| `Daemon/SCDaemonScheduler.m` | Desired-state selection and recovery triggers |
| `Block Management/SCScheduleLaunchdBridge.m` | V1 rollback/drain compatibility only |

---

## 2. System State Transitions

### Sleep/Wake

| Aspect | Implementation | Robustness |
|--------|----------------|------------|
| Explicit handling | `NSWorkspaceDidWakeNotification` triggers reconciliation | Strong |
| Missed-boundary recovery | Root store recomputation plus 60-second backstop | Strong |
| File persistence | Rules in /etc/hosts and PF survive | Strong |

**Note:** Wake and wall-clock/timezone changes explicitly trigger the V2
evaluator. The exact timer improves promptness; the persisted absolute records
provide correctness.

### Shutdown/Reboot

```
System boots
     │
     ▼
launchd starts selfcontrold (RunAtLoad=true)
     │
     ▼
Daemon checks for existing block rules
(SCBlockUtilities.anyBlockIsRunning || blockRulesFoundOnSystem)
     │
     ├── YES → Start checkup timer, resume monitoring
     │
     └── NO → Root scheduler evaluates persisted records
               │
               ▼
         SCDaemonScheduler
         - Reads validated V1/V2 ApprovedSchedules
         - Selects start <= now < end for the relevant owner
         - Starts or defers according to active provenance
```

### Checkup Timer (1-Second Integrity Check)

Every 1 second (`SCDaemonBlockMethods.checkupBlock`):
1. Check if `BlockEndDate` has passed → remove block if expired
2. Verify block exists in settings → stop if removed

Every 15 seconds (`checkBlockIntegrity`):
1. Verify `/etc/hosts` contains SelfControl section
2. Verify PF rules are loaded
3. Verify app blocker is monitoring (if app entries exist)
4. **If any compromised → reinstall all rules**

Plus: **FSEventStream on /etc/hosts** - instant detection (~1.5s) of tampering.

### Transition Safety Boundary

PER-383 deliberately does not claim gapless active-to-active replacement. If a
store mutation selects a different V2 policy while a schedule-owned block is
active, reconciliation defers instead of removing the current physical rules
before applying the next set. Manual and test blocks also defer all schedule
starts.

The pre-existing one-minute inter-segment compatibility gap remains. Closing
it safely requires a separately tested PF/hosts/AppBlocker operation that
stages the new policy before obsolete rules are removed.

### Commitment Admission Safety

`ApprovedScheduleCommitments` keeps the commitment lock in root state even for
a zero-segment week. An unexpired envelope or schedule record (including V1)
rejects a different overlapping batch for the same authenticated owner. The
comparison uses absolute week bounds, not only `weekKey`, so local
defaults/manifest loss or a
travel-induced key shift cannot reopen the interval. Repeating the exact same
batch identity and record content is idempotent. The guard is bidirectional:
legacy V1 registration also rejects an absolute window that overlaps an
unexpired V2 envelope.

Release builds reject bulk approved-schedule clearing even after
authorization. DEBUG builds retain the test operation but clear
`ApprovedSchedules` and `ApprovedScheduleCommitments` together under the
daemon mutation lock. A live V2 record also cannot be removed through the
legacy single-record unregister selector.

Strictification preserves the same fail-closed ordering. If a matching root
record owns the active block, hosts/PF/app additions and active settings must
verify under the daemon mutation lock before the stricter future record is
persisted. Scheduler no-op matching includes commitment/generation, policy,
mode, and content, so identity alone cannot hide weaker active enforcement.

---

## 3. Tamper Resistance Analysis

### Attack Vector Summary

| Attack | Protection | Effectiveness |
|--------|------------|---------------|
| Quit SelfControl.app | Daemon is independent | **Strong** |
| Delete SelfControl.app | Daemon in /Library/PrivilegedHelperTools/ | **Strong** (current block) |
| Kill daemon | KeepAlive=true auto-restarts | **Strong** |
| Edit /etc/hosts | FSEventStream + auto-repair | **Strong** (~1.5s) |
| Flush PF rules | 15s checkup + auto-repair | **Moderate** (15s window) |
| `defaults write` | Settings in root-owned file | **Strong** |
| Remove LaunchAgents | V2 is unaffected; only draining V1 jobs are lost | **Strong for V2 / Weak for V1** |
| Invoke bulk approved-schedule clear | Release daemon rejects it; DEBUG clears records + envelopes together | **Strong in release** |
| Run as different user | Network blocking is system-wide | **Strong** |

### Legacy V1 Vulnerability: Scheduled Jobs in User Space

The following weakness applies only to already-installed V1 rollback/drain
jobs. New V2 commitments are stored and timed by root `selfcontrold` and do not
create these files.

```
Location: ~/Library/LaunchAgents/org.eyebeam.selfcontrol.schedule.*

User CAN:
  - launchctl unload ~/Library/LaunchAgents/...
  - rm ~/Library/LaunchAgents/org.eyebeam.selfcontrol.*

Result: Those V1 scheduled blocks may not trigger
        (V2 commitments and current active blocks are unaffected)
```

---

## 4. Stuck Block Scenarios

### What Could Cause a Stuck Block?

| Scenario | Likelihood | Impact |
|----------|------------|--------|
| macOS restricts /etc/hosts (SIP expansion) | Low (future risk) | Block can't be removed |
| macOS restricts pfctl (entitlement required) | Low (future risk) | Firewall rules persist |
| Daemon binary incompatible with new macOS | Low | Checkup timer stops, rules persist |
| Settings file becomes inaccessible | Very Low | Daemon can't read BlockEndDate |

### What DOESN'T Cause Stuck Blocks

| Concern | Why It's Safe |
|---------|---------------|
| Deprecated `SMJobRemove` | Only affects uninstalling daemon, not removing blocks |
| Deprecated `SMJobBless` | Only affects installing daemon, existing daemon works |
| Private `auditToken` API | Only affects XPC validation, block removal is internal |
| App deletion | Daemon continues independently |

### Code Awareness

The code explicitly acknowledges stuck-block risk (`BlockManager.m:280-285`):

```objc
if ([hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
    NSLog(@"ERROR: Host file backup could not be restored. "
          "This may result in a permanent block.");
}
if ([pf containsSelfControlBlock]) {
    NSLog(@"ERROR: Firewall rules could not be cleared. "
          "This may result in a permanent block.");
}
```

---

## 5. Safety Check System

### Overview

The safety check (`SCStartupSafetyCheck`) runs on **app or macOS version change** and tests the full block/unblock cycle before users can commit to schedules.

**Runs in:** All builds (DEBUG and RELEASE)

**Trigger:** `SCVersionTracker.anyVersionChanged` returns YES

### Two-Phase Test

```
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 1: Normal Block Cycle (30 second test block)            │
├─────────────────────────────────────────────────────────────────┤
│  ✓ hostsBlockWorked    - Can ADD to /etc/hosts?                │
│  ✓ pfBlockWorked       - Can ADD PF rules?                     │
│  ✓ appBlockWorked      - Can kill Calculator?                  │
│  ✓ hostsUnblockWorked  - Can REMOVE from /etc/hosts?           │
│  ✓ pfUnblockWorked     - Can REMOVE PF rules?                  │
│  ✓ appUnblockWorked    - Does Calculator stay running?         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 2: Emergency Script Test (5 minute test block)          │
├─────────────────────────────────────────────────────────────────┤
│  ✓ Start block, verify active                                  │
│  ✓ Run emergency.sh (with sudo prompt)                         │
│  ✓ emergencyScriptWorked - Did it clear everything?            │
└─────────────────────────────────────────────────────────────────┘
```

### Result Reporting

If any check fails, `SCSafetyCheckResult.issues` reports exactly what broke:

- "Hosts file blocking failed"
- "Packet filter blocking failed"
- "App blocking failed (Calculator not killed)"
- "Hosts file unblocking failed"
- "Packet filter unblocking failed"
- "App unblocking failed"
- "Emergency script (emergency.sh) failed to clear block"

### Key Insight

The safety check runs **before users can commit to a schedule**, so if a macOS update breaks blocking:

```
User updates macOS 15 → 16
        │
        ▼
App launches, detects version change
        │
        ▼
Safety Check runs BEFORE user can commit
        │
        ├── PASS → macOS 16 is safe, proceed
        │
        └── FAIL → User warned, can't get stuck
```

### Testing the Safety Check

To manually trigger the safety check (simulates version change):

```bash
defaults delete org.eyebeam.SelfControl SCSafetyCheck_LastTestedAppVersion
defaults delete org.eyebeam.SelfControl SCSafetyCheck_LastTestedOSVersion
```

Then launch the app - it will prompt "Safety Check Recommended" within 1 second.

---

## 6. macOS Compatibility Risks

### High-Risk Dependencies

| API/Feature | Risk Level | Issue |
|-------------|------------|-------|
| `SMJobRemove` | **High** | Deprecated since macOS 10.10 (2014) |
| `SMJobBless` | **Medium-High** | Should migrate to `SMAppService` (macOS 13+) |
| Private `auditToken` | **High** | Not public API, could break |
| `/etc/hosts` modification | **Medium** | No SIP protection now, could change |
| `pfctl` commands | **Low-Medium** | BSD-level, stable but no official API |
| `libproc` process enumeration | **Medium** | TCC restrictions could be added |

### Impact on Stuck Blocks

**Critical insight:** The deprecated APIs primarily affect **starting** blocks, not **removing** them:

| Deprecated API | Block Removal Impact |
|---------------|---------------------|
| `SMJobRemove` | None - daemon can still run and remove blocks |
| `SMJobBless` | None - existing daemon continues working |
| Private `auditToken` | None - block removal is internal to daemon |

**The actual risk** is Apple restricting `/etc/hosts` or `pfctl` - these would affect both the daemon AND emergency.sh since they use the same low-level operations.

---

## 7. Emergency Recovery

### emergency.sh

Located in the app bundle, this script provides manual recovery:

```bash
# 1. Stop daemon
launchctl bootout system/org.eyebeam.selfcontrold

# 2. Clear firewall rules
pfctl -a org.eyebeam -F all
: > /etc/pf.anchors/org.eyebeam
sed -i '' '/org\.eyebeam/d' /etc/pf.conf
pfctl -f /etc/pf.conf

# 3. Clear hosts file
sed -i '' '/# BEGIN SELFCONTROL BLOCK/,/# END SELFCONTROL BLOCK/d' /etc/hosts

# 4. Flush DNS cache
dscacheutil -flushcache
killall -HUP mDNSResponder

# 5. Clear settings
rm /usr/local/etc/.*.plist
```

### Important Caveat

**emergency.sh uses the same operations as the daemon.** If macOS restricts these operations:
- Daemon can't remove block
- emergency.sh ALSO can't remove block

They would fail together. However, the **safety check tests emergency.sh** in Phase 2, so users would be warned before this scenario could occur.

### Manual Recovery (Last Resort)

If both daemon and emergency.sh fail, users with root access can still:

1. Boot into Recovery Mode
2. Disable SIP temporarily
3. Manually edit `/etc/hosts`
4. Manually flush PF rules
5. Re-enable SIP

---

## Robustness Summary Matrix

```
┌─────────────────────────────────────────────────────────────────┐
│                    ROBUSTNESS MATRIX                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CURRENT ACTIVE BLOCK                                            │
│  ├── Sleep/Wake.............. STRONG (wake reconciliation)      │
│  ├── Reboot.................. STRONG (RunAtLoad + recovery)     │
│  ├── App quit/delete......... STRONG (daemon independent)       │
│  ├── Daemon killed........... STRONG (KeepAlive restarts)       │
│  ├── hosts tampering......... STRONG (1.5s detection + repair)  │
│  ├── PF tampering............ MODERATE (15s window)             │
│  └── Root access............. WEAK (can disable everything)     │
│                                                                  │
│  SCHEDULED FUTURE BLOCKS                                         │
│  ├── Reboot.................. STRONG (root records + RunAtLoad)  │
│  ├── LaunchAgent removal..... STRONG V2 / WEAK draining V1      │
│  ├── App deletion............ STRONG V2 (daemon owns timing)    │
│  └── Clock manipulation...... STRONG (absolute dates)           │
│                                                                  │
│  STUCK BLOCK PREVENTION                                          │
│  ├── Normal expiration....... STRONG (checkup timer)            │
│  ├── emergency.sh............ STRONG (tested by safety check)   │
│  ├── Future macOS risk....... DETECTED (safety check catches)   │
│  └── Manual recovery......... POSSIBLE (Recovery Mode)          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Takeaways

1. **Active blocks are highly robust** - survive sleep, reboot, tampering, app deletion
2. **V2 future blocks no longer depend on user LaunchAgents** - V1 retains that weakness only during rollback/drain
3. **Stuck blocks are unlikely** - safety check catches issues before commitment
4. **emergency.sh is tested** - Phase 2 of safety check verifies it works
5. **Biggest risk is macOS changes** - but safety check would detect this

---

## Related Documentation

- [REBOOT_SAFETY_ANALYSIS.md](REBOOT_SAFETY_ANALYSIS.md) - Daemon reboot/restart persistence mechanisms
- [BLOCKING_MECHANISM.md](BLOCKING_MECHANISM.md) - How blocking works technically
- [SYSTEM_ARCHITECTURE.md](../SYSTEM_ARCHITECTURE.md) - Overall system design
- [dictionary/committed-state.md](dictionary/committed-state.md) - Commitment terminology

---

*Last updated: July 2026 (PER-383)*
