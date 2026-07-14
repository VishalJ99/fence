# Daemon Lifecycle

This document describes the lifecycle of the `selfcontrold` daemon, including startup, timers, and persistence behavior.

> **Related:** [SCHEDULE_JOB_LIFECYCLE.md](SCHEDULE_JOB_LIFECYCLE.md) for how scheduled blocks fire.

## Overview

The **selfcontrold** daemon (`org.eyebeam.selfcontrold`) is a privileged root daemon that handles all blocking operations. It runs **permanently** after first install, enabled by `KeepAlive=true` and `RunAtLoad=true`.

Since PER-383 it is also the primary timing authority for V2 committed
schedules. It reads absolute schedule records from root settings and reconciles
them directly; new commitments do not depend on a logged-in user's
LaunchAgents or on `selfcontrol-cli`.

## State Diagram

```mermaid
stateDiagram-v2
    [*] --> NotInstalled

    NotInstalled --> Running: SMJobBless (install or compatibility repair)

    state Running {
        [*] --> Idle

        Idle --> ActiveBlock: Block starts
        ActiveBlock --> Idle: Block expires/cleared

        state Idle {
            note right of Idle
                - Exact boundary timer
                - 60s scheduler backstop
                - XPC listener active
                - Hosts file watcher
            end note
        }

        state ActiveBlock {
            note right of ActiveBlock
                - Checkup timer (1 sec)
                - PF rules active
                - /etc/hosts modified
                - AppBlocker (if app entries)
            end note
        }
    }

    Running --> Running: KeepAlive restarts if killed
    Running --> Running: RunAtLoad on reboot
```

## Daemon Startup

### Installation via SMJobBless

The daemon is installed or replaced by the helper compatibility/repair path,
or when a manual block first needs the helper:

```objc
// In SCXPCClient.m
SMJobBless(kSMDomainSystemLaunchd, CFSTR("org.eyebeam.selfcontrold"), ...);
```

**Triggers:**
- User starts a manual block
- App detects a missing or incompatible protocol/capability set
- A V2 commit may invoke that repair path before its batch request, but an
  ordinary compatible commit does not call `SMJobBless`

### Entry Point

```objc
// DaemonMain.m
int main(int argc, const char *argv[]) {
    SCDaemon* daemon = [SCDaemon sharedDaemon];
    [daemon start];  // Initialize all subsystems
    [[NSRunLoop currentRunLoop] run];  // Never returns
    return 0;
}
```

### The `-start` Method

When the daemon starts, it initializes:

1. **XPC Listener** — Accepts connections from the app
2. **Checkup Timer** — Starts only if block is running (1-second interval)
3. **Root Schedule Evaluator** — Starts immediately and arms the next exact
   wall-clock boundary
4. **Schedule Backstop** — Re-evaluates every 60 seconds
5. **Wake/Clock/Timezone Observers** — Re-evaluate after discontinuities
6. **Hosts File Watcher** — Detects tampering during active blocks

```objc
- (void)start {
    [self.listener resume];

    if ([SCBlockUtilities anyBlockIsRunning]) {
        [self startCheckupTimer];
    }

    // Observe wake, wall-clock changes, and timezone changes.
    // The injected scheduler reads root ApprovedSchedules on every evaluation.
    [self.scheduler start];
}
```

## Timer Architecture

### Summary

| Timer | Interval | Purpose | When Active |
|-------|----------|---------|-------------|
| **Checkup Timer** | 1 second | Verify block integrity, expire blocks | Only during active block |
| **Schedule Boundary Timer** | One-shot at next absolute start/end | Prompt schedule transition | When a future boundary exists |
| **Schedule Backstop** | 60 seconds | Recover from missed/coalesced triggers | Always |
| **Inactivity Timer** | N/A | Previously used for daemon exit | **DISABLED** |

### Checkup Timer (1-second)

Runs only when a block is active. Every second:

1. **Block expired?** → Remove block, stop timer
2. **No block flag but rules exist?** → Clean up remnants
3. **Block active?** → Every 15 seconds, verify integrity:
   - PF rules intact
   - /etc/hosts entries exist
   - AppBlocker running (if needed)
   - If compromised: re-add all rules

```objc
self.checkupTimer = [NSTimer scheduledTimerWithTimeInterval: 1
                                                    repeats: YES
                                                      block:^(NSTimer * _Nonnull timer) {
    [SCDaemonBlockMethods checkupBlock];
}];
```

### Root Schedule Evaluator

`SCDaemonScheduler` owns a serial queue and recomputes desired enforcement from
the persisted V1/V2 records. It uses half-open bounds
`approvedStartDate <= now < approvedEndDate`, arms a one-shot
`dispatch_walltime` timer for the next record boundary, and runs a coalesced
60-second backstop.

Evaluation also runs at startup, wake, wall-clock change, timezone change,
schedule mutation, and active-block completion. A timer firing is never trusted
as state by itself; the evaluator reloads the root store and current active
provenance every time.

`ApprovedScheduleCommitments` is the companion root admission store. Its
immutable owner/absolute-week envelopes survive reboot and include
zero-segment commitments; they prevent a different unexpired overlapping
batch, while `SCDaemonScheduler` selects enforcement only from segment records.
Any unexpired overlapping schedule record also blocks V2 admission; in
particular, V1 records drain rather than being replaced.

The compatibility rule is symmetric. A legacy V1 registration is rejected if
its absolute window overlaps an unexpired V2 envelope for the authenticated
owner. Bulk clearing cannot bypass either rule in production: release builds
reject that selector, while DEBUG tests clear both the record and envelope maps
together under the daemon mutation lock.

If a manual or test block is active, the schedule waits. If another
schedule-owned policy is active and a mutation selects a different V2 record,
the evaluator also waits rather than weakening enforcement with
remove-then-add. A verified scheduler no-op requires matching schedule/owner
provenance, mode and content; V2 additionally matches commitment, generation,
and policy revision. See
[SCHEDULE_JOB_LIFECYCLE.md](SCHEDULE_JOB_LIFECYCLE.md).

The old `startMissedBlockIfNeeded` LaunchAgent scan is no longer a V1 or V2
recovery mechanism. V1 LaunchAgents and selectors remain only as redundant
bounded rollback/drain triggers.

### Inactivity Timer (DISABLED)

The daemon previously had an inactivity timeout that would exit after 2 minutes of inactivity. This is now **disabled** — the daemon runs permanently.

```objc
float const INACTIVITY_LIMIT_SECS = 60 * 2; // No longer used

- (void)startInactivityTimer {
    // Daemon now runs permanently for:
    // 1. Scheduled blocks (no password prompts)
    // 2. Jailbreak resistance (KeepAlive restarts if killed)
    // 3. Resource usage is negligible
}
```

## Persistence & KeepAlive

### Launchd Configuration

```xml
<!-- org.eyebeam.selfcontrold.plist -->
<dict>
    <key>Label</key>
    <string>org.eyebeam.selfcontrold</string>

    <key>RunAtLoad</key>
    <true/>              <!-- Start on boot -->

    <key>KeepAlive</key>
    <true/>              <!-- Restart if killed -->

    <key>MachServices</key>
    <dict>
        <key>org.eyebeam.selfcontrold</key>
        <true/>          <!-- XPC service name -->
    </dict>
</dict>
```

### Behavior

| Scenario | Result |
|----------|--------|
| System boot | Daemon starts (`RunAtLoad=true`) |
| Daemon crashes | launchd restarts it (`KeepAlive=true`) |
| User kills daemon | launchd restarts it |
| Daemon exits cleanly | launchd restarts it |

This is **intentional for tamper resistance**. Users cannot circumvent blocking by killing the daemon.

## Timer Interaction

```
Boot/Install
    │
    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Daemon -start method                                                    │
│   • XPC listener resumed                                                │
│   • Root scheduler evaluates persisted records                          │
│   • Exact next-boundary timer + 60s backstop start                      │
│   • Wake/clock/timezone observers register                              │
│   • Start checkup timer IF block already running                        │
└─────────────────────────────────────────────────────────────────────────┘
    │
    │  No block running:
    │  ┌─────────────────────────────────────────────────────────────────┐
    │  │ Scheduler evaluates at exact boundary or recovery trigger        │
    │  │   → Reads root ApprovedSchedules                                 │
    │  │   → Selects desired half-open V1/V2 record                       │
    │  │   → Starts or defers according to active provenance              │
    │  └─────────────────────────────────────────────────────────────────┘
    │
    │  Block starts:
    │  ┌─────────────────────────────────────────────────────────────────┐
    │  │ Checkup timer starts (1 sec)                                    │
    │  │   → checkupBlock every second                                   │
    │  │   → Integrity check every 15s                                   │
    │  │   → Expires block when endDate passes                           │
    │  └─────────────────────────────────────────────────────────────────┘
    │
    │  Block expires:
    │  ┌─────────────────────────────────────────────────────────────────┐
    │  │ Checkup timer stops                                             │
    │  │ Scheduler receives completion and selects the next boundary      │
    │  └─────────────────────────────────────────────────────────────────┘
    │
    ▼
   (daemon runs forever)
```

## Resource Usage

The daemon is designed to be lightweight:

| Resource | Usage |
|----------|-------|
| Memory | ~5-10 MB |
| CPU (idle) | 0% |
| CPU (schedule evaluation) | Bounded exact-boundary work plus a 60s backstop |
| CPU (active block) | < 1ms every second |

## Key Files

| File | Purpose |
|------|---------|
| `Daemon/SCDaemon.m` | Main daemon class, timers, lifecycle |
| `Daemon/SCDaemon.h` | Header |
| `Daemon/SCDaemonScheduler.m` | Root schedule selection, timers, and serialized reconciliation |
| `Daemon/SCDaemonScheduler.h` | Scheduler contract and V2/provenance constants |
| `Daemon/DaemonMain.m` | Entry point |
| `Daemon/SCDaemonBlockMethods.m` | Block operations, checkup logic |
| `Daemon/SCDaemonXPC.m` | XPC interface handlers |
| `Daemon/org.eyebeam.selfcontrold.plist` | launchd configuration |

---

*Last updated: July 2026 (PER-383)*
