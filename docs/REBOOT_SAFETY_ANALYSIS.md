# Daemon Reboot/Restart Safety Analysis

> **Purpose:** Technical analysis of how the daemon persists blocking sessions across system restarts, sleep/wake cycles, and user tampering attempts.
>
> **Key Question:** "After a reboot, will my block still be active?"
>
> **Last Updated:** July 2026 (PER-383)

---

## Executive Summary

Fence uses a **three-layer persistence architecture** to ensure blocks survive system restarts:

1. **Settings Flag** - `BlockIsRunning=YES` in root-owned plist
2. **Filesystem Rules** - Blocking markers in `/etc/hosts` and PF anchors
3. **Root Schedule Reconciliation** - `SCDaemonScheduler` recomputes the desired V1/V2 record from absolute dates

**Robustness Verdict:**

| Aspect | Rating | Summary |
|--------|--------|---------|
| Reboot Persistence | **STRONG** | Active state, physical remnants, and root schedule records are recovered at `RunAtLoad` |
| Tampering Resistance | **STRONG** | Auto-repair within 1.5-15 seconds |
| macOS Compatibility | **MODERATE** | Deprecated APIs, but safety check mitigates |
| Edge Case Handling | **MODERATE** | Some gaps (Safe Mode, Recovery Mode) |

---

## Table of Contents

1. [Multi-Layer Persistence Architecture](#1-multi-layer-persistence-architecture)
2. [Daemon Boot Sequence](#2-daemon-boot-sequence)
3. [Scheduled Block Recovery](#3-scheduled-block-recovery)
4. [Continuous Monitoring Architecture](#4-continuous-monitoring-architecture)
5. [User Tampering Resistance](#5-user-tampering-resistance)
6. [macOS Update Risks](#6-macos-update-risks)
7. [Edge Cases and Failure Modes](#7-edge-cases-and-failure-modes)
8. [Settings Synchronization Safety](#8-settings-synchronization-safety)
9. [Overall Safety Verdict](#9-overall-safety-verdict)
10. [Appendix: Code References](#appendix-code-references)

---

## 1. Multi-Layer Persistence Architecture

The daemon uses three independent detection mechanisms to ensure blocks survive reboots:

```
System boots
     │
     ▼
launchd starts selfcontrold (RunAtLoad=true, KeepAlive=true)
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                    THREE-LAYER DETECTION                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  LAYER 1: Settings Flag                                          │
│  ├── Location: /usr/local/etc/.{SHA1}.plist                     │
│  ├── Key: BlockIsRunning = YES                                  │
│  ├── Owner: root (0755)                                         │
│  └── Check: SCBlockUtilities.modernBlockIsRunning               │
│                                                                  │
│  LAYER 2: Filesystem Rules                                       │
│  ├── /etc/hosts contains "# BEGIN SELFCONTROL BLOCK"            │
│  ├── /etc/pf.anchors/org.eyebeam contains rules                 │
│  └── Check: SCBlockUtilities.blockRulesFoundOnSystem            │
│                                                                  │
│  LAYER 3: Root Schedule Reconciliation                           │
│  ├── V1/V2 ApprovedSchedules in daemon settings                 │
│  ├── Immutable V2 ApprovedScheduleCommitments envelopes         │
│  ├── Absolute half-open start/end bounds                        │
│  └── Check: SCDaemonScheduler startup evaluation               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼
ANY layer detects block → Start checkup timer (1-second monitoring)
```

### What Data Survives Reboot

| Data | Location | Owner | Protected By |
|------|----------|-------|--------------|
| `BlockIsRunning` flag | `/usr/local/etc/.{hash}.plist` | root | Filesystem permissions |
| `BlockEndDate` | Same plist | root | Filesystem permissions |
| `ActiveBlocklist` | Same plist | root | Filesystem permissions |
| DNS redirect rules | `/etc/hosts` | root | FSEventStream watcher |
| Firewall rules | `/etc/pf.anchors/org.eyebeam` | root | 15-second integrity check |
| Hosts backup | `/etc/hosts.bak` | root | Used for recovery |
| Approved schedules | Daemon plist | root | Pre-authorized on commit |
| V2 commitment envelopes | Daemon plist | root | Immutable owner/absolute-week admission, including zero segments |
| Active provenance | Daemon plist | root | Distinguishes manual/test/V1/V2 ownership |
| V1 Launchd jobs (drain only) | `~/Library/LaunchAgents/` | user | launchd persistence |

---

## 2. Daemon Boot Sequence

When the system boots, `launchd` starts the daemon due to `RunAtLoad=true` in its plist configuration.

### SCDaemon.start() Flow

**Source:** `Daemon/SCDaemon.m:57-95`

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: Resume XPC Listener                                     │
│  [self.listener resume]                                          │
│  → Daemon ready to receive commands from SelfControl.app         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: Check for Existing Block                                │
│                                                                  │
│  if ([SCBlockUtilities anyBlockIsRunning] ||                     │
│      [SCBlockUtilities blockRulesFoundOnSystem]) {               │
│      [self startCheckupTimer];  // 1-second interval             │
│  }                                                               │
│                                                                  │
│  Detection methods:                                              │
│  ├── modernBlockIsRunning: Check BlockIsRunning=YES in settings  │
│  ├── legacyBlockIsRunning: Check old v3.x lock files             │
│  └── blockRulesFoundOnSystem: Scan /etc/hosts + PF anchor        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: Start Root Schedule Evaluator                           │
│                                                                  │
│  [self.scheduler start];                                         │
│                                                                  │
│  → Reads root records, reconciles NOW, arms next exact boundary   │
│  → Also registers wake/clock/timezone recovery triggers           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 4: Start Hosts File Watcher                                │
│                                                                  │
│  self.hostsFileWatcher = [SCFileWatcher watcherWithFile:         │
│      @"/etc/hosts" block:^{                                      │
│          [SCDaemonBlockMethods checkBlockIntegrity];             │
│      }];                                                         │
│                                                                  │
│  → FSEventStream triggers on any /etc/hosts modification         │
│  → Detection time: ~1.5 seconds                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why Three Layers?

Each layer serves as a fallback for the others:

| Scenario | Layer 1 (Settings) | Layer 2 (Filesystem) | Layer 3 (Schedule) |
|----------|-------------------|---------------------|-------------------|
| Normal block running | Detects | Confirms | N/A |
| Settings file deleted | FAILS | Detects | N/A |
| Reboot during scheduled block | May not detect | May detect | **Recovers** |
| Block rules manually cleared | Detects | FAILS | N/A |

---

## 3. Scheduled Block Recovery

### Current V2 Root-Store Reconciliation

At daemon startup, `SCDaemonScheduler` reads validated records owned by the
relevant console/active user, selects the desired record using
`approvedStartDate <= now < approvedEndDate`, and reconciles it through
`SCDaemonBlockMethods`. It then arms a one-shot wall-clock timer for the next
start/end boundary.

The same evaluation runs after wake, wall-clock or timezone changes, schedule
mutation, and active-block completion, plus a 60-second backstop. This makes
restart recovery independent of login, Background Items permission, a CLI
path, and per-segment user plists.

Manual and test blocks are not replaced. A V2 mutation that selects a
different schedule while a schedule-owned block is active also defers rather
than executing an unsafe remove-then-add transition. The existing one-minute
inter-segment compatibility gap remains.

The separate root `ApprovedScheduleCommitments` map preserves admission state
across reboot even when app-local commitment defaults/manifests are absent.
The scheduler evaluates segment records; the envelope prevents a different
unexpired overlapping commitment from being admitted, including when travel
changed the local `weekKey` or the commitment has zero segments. Any unexpired
overlapping schedule record blocks admission; live V1 records specifically
drain rather than being replaced. Legacy registration reciprocally rejects a
window overlapping an unexpired V2 envelope. Release builds cannot bulk-clear
either authority map; the DEBUG-only test path clears records and envelopes
together under the daemon mutation lock.

### Legacy V1 `startMissedBlockIfNeeded` Reference

> The following implementation description applies to the pre-PER-383 V1
> LaunchAgent path and is retained for bounded rollback/drain support. It is
> not the recovery mechanism for a V2 record.

This legacy recovery mechanism handles the case where:
- The system rebooted during a scheduled block window
- The launchd job didn't fire because the system was off at the scheduled start time

**Source:** `Daemon/SCDaemon.m:159-341`

#### Recovery Logic Flow

```
startMissedBlockIfNeeded()
         │
         ▼
┌─────────────────────────────────────────┐
│  Pre-checks                              │
│  ├── Block already running? → EXIT      │
│  ├── ApprovedSchedules empty? → EXIT    │
│  └── No console user? → EXIT            │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  Scan LaunchAgents directory            │
│                                          │
│  ~/Library/LaunchAgents/                 │
│    org.eyebeam.selfcontrol.schedule.    │
│    merged-{UUID}.{weekday}.{time}.plist │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  For each launchd job:                   │
│                                          │
│  Extract from plist:                     │
│  ├── StartCalendarInterval:              │
│  │   ├── Weekday (0=Sun, 6=Sat)         │
│  │   ├── Hour                           │
│  │   └── Minute                         │
│  │                                       │
│  └── ProgramArguments:                   │
│      └── --enddate=2025-01-15T18:00:00Z │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  Check if active NOW:                    │
│                                          │
│  sameWeekday = (jobWeekday == nowWeekday)│
│  startedOrNow = (jobStart <= nowMinutes) │
│  endsInFuture = (endDate > now)          │
│                                          │
│  if (sameWeekday && startedOrNow &&      │
│      endsInFuture) {                     │
│      → This segment should be active!    │
│  }                                       │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  Start the block (NO PASSWORD!)          │
│                                          │
│  [SCDaemonBlockMethods                   │
│      startBlockWithControllingUID:uid    │
│      blocklist:blocklist                 │
│      isAllowlist:isAllowlist             │
│      endDate:activeEndDate               │
│      blockSettings:blockSettings         │
│      authorization:nil   ← Pre-approved! │
│      reply:...];                         │
└─────────────────────────────────────────┘
```

#### Why authorization:nil Worked

When the user commits to a week schedule:
1. They authenticate with password (once)
2. The daemon stores the schedule in `ApprovedSchedules` (root-owned)
3. Each segment gets a unique UUID
4. On boot, the daemon verifies the UUID exists in `ApprovedSchedules`
5. If valid, the block starts without re-authentication

**Security:** A user cannot forge `ApprovedSchedules` because:
- The file is owned by root (uid 0)
- Regular users have read-only access
- Only the daemon (running as root) can write to it

---

## 4. Continuous Monitoring Architecture

Once a block is detected or started, the daemon runs continuous monitoring.

### Timer Hierarchy

| Timer | Interval | Purpose | Source |
|-------|----------|---------|--------|
| Checkup timer | 1 second | Block expiration, state verification | `SCDaemon.m:111` |
| Integrity check | 15 seconds | Full rule verification | `SCDaemonBlockMethods.m:355` |
| Schedule boundary | One-shot absolute time | Prompt V1/V2 start/end reconciliation | `SCDaemonScheduler.m` |
| Schedule backstop | 60 seconds | Recover missed/coalesced triggers | `SCDaemonScheduler.m` |
| FSEventStream | ~1.5s throttle | Instant /etc/hosts detection | `SCFileWatcher.m` |
| Settings sync | 30 seconds | Disk persistence | `SCSettings.m:477` |
| App blocker poll | 500 ms | Process monitoring | `AppBlocker.m:16` |

### Checkup Cycle (Every 1 Second)

**Source:** `Daemon/SCDaemonBlockMethods.m:306-371`

```objc
+ (void)checkupBlock {
    // 1. Is block still registered?
    if (![SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"No active block found");
        [SCHelperToolUtilities removeBlock];
        [[SCDaemon sharedDaemon] stopCheckupTimer];
        return;
    }

    // 2. Has block expired?
    if ([SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"Block expired, removing");
        [SCHelperToolUtilities removeBlock];
        [[SCDaemon sharedDaemon] stopCheckupTimer];
        return;
    }

    // 3. Every 15 seconds: Full integrity check
    if (timeSinceLastIntegrityCheck > 15.0) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}
```

### Integrity Check (Every 15 Seconds)

**Source:** `Daemon/SCDaemonBlockMethods.m:373-434`

```objc
+ (void)checkBlockIntegrity {
    // Check all three blocking mechanisms
    BOOL pfIntact = [pf containsSelfControlBlock];
    BOOL hostsIntact = [hostFileBlocker containsSelfControlBlock];
    BOOL appBlockingIntact = !hasAppEntries || appBlocker.isMonitoring;

    // If ANY layer is compromised → Reinstall everything
    if (!pfIntact || !hostsIntact || !appBlockingIntact) {
        NSLog(@"Block integrity compromised, reinstalling...");

        // Clear old rules first
        [pf stopBlock:false];
        [hostFileBlockerSet removeSelfControlBlock];

        // Restore from backup if needed
        [hostFileBlockerSet restoreBackupHostsFile];

        // Reinstall all rules from settings
        [SCHelperToolUtilities installBlockRulesFromSettings];
    }
}
```

### Detection and Repair Timeline

```
Tampering event occurs at T=0
         │
         ├─── /etc/hosts modified
         │         │
         │         ▼
         │    FSEventStream fires (~1.5s)
         │         │
         │         ▼
         │    checkBlockIntegrity runs
         │         │
         │         ▼
         │    Rules reinstalled (T ≈ 2s)
         │
         ├─── PF rules flushed
         │         │
         │         ▼
         │    Next 15-second integrity check
         │         │
         │         ▼
         │    Rules reinstalled (T ≤ 15s)
         │
         └─── Settings plist modified
                   │
                   ▼
              Requires root access
              Next 1-second checkup detects
              (T ≤ 1s)
```

---

## 5. User Tampering Resistance

### Attack Vector Analysis

| Attack | Mitigation | Detection Time | Effectiveness |
|--------|------------|----------------|---------------|
| **Kill daemon process** | `KeepAlive=true` in launchd config | <1 second | **STRONG** |
| **`launchctl bootout` daemon** | None until next app install | Permanent | **WEAK** |
| **Edit /etc/hosts** | FSEventStream watcher + auto-repair | ~1.5 seconds | **STRONG** |
| **`pfctl -F all` (flush PF)** | 15-second integrity check | ≤15 seconds | **MODERATE** |
| **Delete settings plist** | Filesystem detection fallback | 1 second | **MODERATE** |
| **Modify BlockEndDate** | Requires root; daemon re-reads | Next sync | **MODERATE** |
| **Change system clock backwards** | Uses absolute NSDate, not elapsed | Immediate | **STRONG** |
| **Change system clock forwards** | Block expires on next checkup | 1 second | **STRONG** |
| **Boot Safe Mode** | Daemon may not load | Full boot | **WEAK** |
| **Boot Recovery Mode** | Full system access | N/A | **UNMITIGATED** |

### Time Manipulation Resistance

The daemon uses **absolute timestamps**, not elapsed time:

```objc
// SCBlockUtilities.m:54-62
+ (BOOL)currentBlockIsExpired {
    NSDate* endDate = [settings valueForKey:@"BlockEndDate"];

    // Compare absolute times
    if ([endDate timeIntervalSinceNow] > 0) {
        return NO;   // End date is still in the future
    } else {
        return YES;  // End date has passed
    }
}
```

**Implications:**
- Setting clock **backwards** → Block won't expire early (user still blocked)
- Setting clock **forwards** → Block expires immediately on next 1-second checkup

### launchd KeepAlive Protection

**Source:** Daemon's launchd plist configuration

```xml
<key>KeepAlive</key>
<true/>

<key>RunAtLoad</key>
<true/>
```

If the daemon process is killed:
1. launchd detects termination
2. launchd restarts daemon immediately (<1 second)
3. Daemon runs `start()` again
4. Block is re-detected and monitoring resumes

---

## 6. macOS Update Risks

### API Dependencies

| API/Feature | Status | Risk Level | Impact if Broken |
|-------------|--------|------------|------------------|
| `SMJobBless` | Deprecated (macOS 10.10) | **HIGH** | Can't install daemon |
| `SMJobRemove` | Deprecated (macOS 10.10) | **MEDIUM** | Can't uninstall daemon |
| Private `auditToken` | Not public API | **HIGH** | XPC validation fails |
| `/etc/hosts` modification | No SIP protection currently | **MEDIUM** | DNS blocking fails |
| `pfctl` commands | BSD subsystem | **LOW-MEDIUM** | Firewall blocking fails |
| `libproc` APIs | System framework | **MEDIUM** | App blocking fails |
| FSEventStream | Public API | **LOW** | File watching fails |

### Critical Insight: Asymmetric Risk

Block **REMOVAL** is more resilient than block **INSTALLATION**:

| Operation | APIs Used | Risk if Deprecated |
|-----------|-----------|-------------------|
| Install daemon | `SMJobBless` | Can't start new blocks |
| Start block | XPC + authorization | Requires valid daemon |
| **Remove block** | Internal daemon operations | **Still works** |
| **Checkup/integrity** | Internal daemon operations | **Still works** |

**Why this matters:** Even if Apple deprecates installation APIs, an existing daemon can still:
- Detect block state
- Run checkup timers
- Remove blocks when they expire
- Repair tampered rules

### Safety Check Mitigation

The startup safety check (see [BLOCK_SAFETY_ANALYSIS.md](BLOCK_SAFETY_ANALYSIS.md#5-safety-check-system)) runs on app/OS version change and tests the full block/unblock cycle. If a macOS update breaks blocking mechanisms, users are warned **before** they can commit to a schedule.

---

## 7. Edge Cases and Failure Modes

### Scenario Matrix

| Scenario | Block State After Boot | Detection Mechanism |
|----------|------------------------|---------------------|
| Normal reboot during active block | **ACTIVE** | `BlockIsRunning=YES` detected |
| Block expires during shutdown | **CLEARED** | `checkupBlock` clears on first run |
| Crash/reboot during V2 scheduled window | **RECOVERED** | Root scheduler startup evaluation |
| Wake after crossing a V2 boundary | **RECOVERED** | Explicit wake evaluation plus 60-second backstop |
| Settings file deleted/corrupted | **DETECTED** | `blockRulesFoundOnSystem()` fallback |
| /etc/hosts manually cleared | **RESTORED** | `checkBlockIntegrity()` reinstalls |
| PF rules flushed | **RESTORED** | 15-second integrity check |
| Daemon binary corrupted | **FAILS** | Daemon can't start |

### Power Failure During Block Installation

```
User clicks "Start Block"
         │
         ▼
    Write /etc/hosts ← POWER FAILURE HERE
         │
         ▼
    System reboots
         │
         ▼
    Daemon starts
         │
         ├── BlockIsRunning may be YES (if settings written)
         │   └── checkBlockIntegrity reinstalls rules
         │
         └── BlockIsRunning is NO (if settings not written)
             └── blockRulesFoundOnSystem detects partial rules
                 └── Partial block detected and completed
```

### Sleep/Wake Handling

The daemon explicitly observes `NSWorkspaceDidWakeNotification` and asks the
serialized root scheduler to re-evaluate. It also relies on:

1. **Root-store recomputation** - desired state is derived from absolute dates,
   not from whether a timer fired while awake
2. **60-second backstop** - recovers a coalesced/missed wake or clock event
3. **Filesystem persistence** - active `/etc/hosts` and PF rules survive sleep
4. **Checkup timer continuation** - active-block expiry/integrity resumes after
   wake

This works because:
- The block end date is absolute (not a countdown)
- If the system sleeps past the end date, the first checkup after wake clears the block

---

## 8. Settings Synchronization Safety

### Persistence Layer

**Source:** `Common/SCSettings.m`

The daemon uses a sophisticated settings system with version tracking:

```objc
// Key fields for synchronization
@"SettingsVersionNumber"  // Integer, increments on change
@"LastSettingsUpdate"     // NSDate, timestamp of last update
```

### Conflict Resolution

When settings are read from disk:

```objc
// SCSettings.m:179-223
- (void)reloadSettings {
    NSInteger diskVersion = [diskSettings[@"SettingsVersionNumber"] integerValue];
    NSInteger memoryVersion = [self.settingsDict[@"SettingsVersionNumber"] integerValue];

    if (diskVersion > memoryVersion) {
        // Disk is newer → Reload
        self.settingsDict = diskSettings;
    } else if (diskVersion == memoryVersion) {
        // Tiebreak with timestamp
        NSDate* diskUpdate = diskSettings[@"LastSettingsUpdate"];
        NSDate* memoryUpdate = self.settingsDict[@"LastSettingsUpdate"];

        if ([diskUpdate compare:memoryUpdate] == NSOrderedDescending) {
            self.settingsDict = diskSettings;
        }
    }
    // If memory is newer, keep memory (will sync to disk later)
}
```

### Sync Timer

- **Interval:** Every 30 seconds
- **Critical writes:** Use `syncSettingsAndWait(5)` for synchronous persistence
- **Crash safety:** Uses `NSDataWritingAtomic` for atomic file writes

### Risk: Settings Desync

| Scenario | Mitigation |
|----------|------------|
| Daemon crashes before sync | Next boot re-reads from disk |
| Disk write fails | Log warning, retry on next sync |
| Multiple processes conflict | Version number resolution |
| File corruption | Block detected via filesystem rules fallback |

---

## 9. Overall Safety Verdict

### Robustness Scorecard

| Aspect | Rating | Justification |
|--------|--------|---------------|
| **Reboot Persistence** | **STRONG** | Active settings, filesystem remnants, and root schedule reconciliation |
| **Tampering Resistance** | **STRONG** | Auto-repair within 1.5-15 seconds; KeepAlive restarts daemon |
| **macOS Compatibility** | **MODERATE** | Uses deprecated APIs; safety check mitigates risk |
| **Edge Case Handling** | **MODERATE** | Some gaps (Safe Mode, Recovery Mode, daemon corruption) |
| **Time Manipulation** | **STRONG** | Uses absolute timestamps; clock changes handled correctly |
| **Settings Safety** | **STRONG** | Version-controlled sync; atomic writes; corruption fallback |

### Key Findings

1. **Blocks reliably survive reboots** through three independent detection mechanisms
2. **Tampering is auto-repaired** within 1.5 seconds (hosts) to 15 seconds (PF)
3. **V2 scheduled blocks recover** from root records without a user login, LaunchAgent, or CLI path
4. **The main risk is macOS platform changes**, but:
   - Block removal is more resilient than installation
   - Safety check detects issues before users can get stuck
5. **Unmitigated gaps exist** for Recovery Mode and Safe Mode boot

### Recommendations for Future Improvement

| Priority | Improvement | Rationale |
|----------|-------------|-----------|
| **HIGH** | Migrate from `SMJobBless` to `SMAppService` | Replace deprecated API (macOS 13+) |
| **MEDIUM** | Reduce PF integrity check to 5 seconds | Smaller tampering window |
| **MEDIUM** | Add fault-injection coverage for wake/clock/timezone coalescing | Prove every recovery trigger against persisted records |
| **MEDIUM** | Build staged active-to-active replacement | Remove the one-minute compatibility gap without remove-then-add |
| **LOW** | Add daemon health watchdog | Detect daemon hangs |

---

## Appendix: Code References

### Critical Files

| File | Purpose | Key Lines |
|------|---------|-----------|
| `Daemon/SCDaemon.m` | Boot sequence, XPC listener, scheduler trigger wiring | `-start`, `scheduleStateDidChangeWithTrigger:` |
| `Daemon/SCDaemonScheduler.m` | Root record selection, exact boundary/backstop timers, serialized reconciliation | `performEvaluationForTrigger:`, `armBoundaryAfterDate:` |
| `Daemon/SCDaemonBlockMethods.m` | Checkup timer, integrity checks, schedule provenance | `checkupBlock`, `checkBlockIntegrity`, scheduled start/end methods |
| `Common/SCSettings.m` | Settings persistence | 179-223 (reload), 467-482 (sync) |
| `Common/Utility/SCBlockUtilities.m` | Block state detection | 14-66 (all detection methods) |
| `Common/SCFileWatcher.m` | FSEventStream wrapper | 42-93 (file monitoring) |
| `Block Management/BlockManager.m` | Block installation/removal | Core blocking operations |

### launchd Configuration

**Location:** `/Library/LaunchDaemons/org.eyebeam.selfcontrold.plist` (installed via SMJobBless)

Key properties:
```xml
<key>KeepAlive</key>
<true/>          <!-- Restart if killed -->

<key>RunAtLoad</key>
<true/>          <!-- Start on boot -->

<key>MachServices</key>
<dict>
    <key>org.eyebeam.selfcontrold</key>
    <true/>      <!-- XPC service registration -->
</dict>
```

---

## Related Documentation

- [BLOCK_SAFETY_ANALYSIS.md](BLOCK_SAFETY_ANALYSIS.md) - Stuck block prevention, safety check system
- [BLOCKING_MECHANISM.md](BLOCKING_MECHANISM.md) - How blocking works technically
- [SYSTEM_ARCHITECTURE.md](../SYSTEM_ARCHITECTURE.md) - Overall system design

---

*Last updated: July 2026 (PER-383)*
