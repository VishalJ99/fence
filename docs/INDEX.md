# SelfControl Documentation Index

## Quick Lookup

| Task | Doc | Files |
|------|-----|-------|
| Architecture | [SYSTEM_ARCHITECTURE.md](../SYSTEM_ARCHITECTURE.md) | - |
| Blocking | [BLOCKING_MECHANISM.md](BLOCKING_MECHANISM.md) | BlockManager.m, PacketFilter.m, HostFileBlocker.m |
| App blocking | [BLOCKING_MECHANISM.md#app-blocking](BLOCKING_MECHANISM.md#app-blocking-implementation) | AppBlocker.m, SCBlockEntry.m |
| Safety/Robustness | [BLOCK_SAFETY_ANALYSIS.md](BLOCK_SAFETY_ANALYSIS.md) | SCStartupSafetyCheck.m, emergency.sh |
| Scheduling | [dictionary.md](dictionary.md) | SCScheduleManager.m, SCScheduleLaunchdBridge.m |
| Schedule job lifecycle | [SCHEDULE_JOB_LIFECYCLE.md](SCHEDULE_JOB_LIFECYCLE.md) | SCScheduleManager.m, cli-main.m, SCDaemon.m |
| **Daemon Lifecycle** | [DAEMON_LIFECYCLE.md](DAEMON_LIFECYCLE.md) | SCDaemon.m, org.eyebeam.selfcontrold.plist |
| **Telemetry policy (Sentry)** | [TELEMETRY.md](TELEMETRY.md) | SCSentry.m, SCSettings.m, SCLogger.m |
| **Timezone Handling** | [TIMEZONE_HANDLING.md](TIMEZONE_HANDLING.md) | SCScheduleManager.m, cli-main.m, SCDaemon.m |
| Terminology | [dictionary.md](dictionary.md) | See dictionary/ folder for full entries |
| Debug features | [SYSTEM_ARCHITECTURE.md#6-debug-features](../SYSTEM_ARCHITECTURE.md#6-debug-features) | SCDebugUtilities.m |
| UI | - | AppController.m, *.xib |
| XPC | - | SCDaemonProtocol.h, SCDaemonXPC.m, SCXPCClient.m |

## Architecture

```mermaid
graph TB
    subgraph User[User Space]
        App[SelfControl.app] --> XPC
        CLI[selfcontrol-cli] --> XPC
    end
    subgraph Root[Privileged - root]
        XPC --> Daemon[selfcontrold]
        Daemon --> HF[/etc/hosts]
        Daemon --> PF[pfctl]
    end
```

## Module Map

**App Layer:**
- AppController.m: Main UI coordinator
- SCMenuBarController.m: Menu bar status item (primary UI when committed)
- SCWeekScheduleWindowController.m: Week schedule grid and bundle management
- TimerWindowController.m: Legacy timer display (blocklist viewer)
- DomainListWindowController.m: Blocklist editor
- SCSafetyCheckWindowController.m: Startup safety test UI

**Daemon Layer (Daemon/):**
- SCDaemon.m: Lifecycle, timers
- SCDaemonXPC.m: XPC handler
- SCDaemonBlockMethods.m: Block operations

**Blocking Layer (Block Management/):**
- BlockManager.m: Orchestrator
- HostFileBlocker.m: /etc/hosts
- PacketFilter.m: PF rules
- AppBlocker.m: Process killer
- SCBlockEntry.m: Entry model

**Scheduling Layer (Block Management/):**
- SCScheduleManager.m: Bundle/schedule orchestrator
- SCScheduleLaunchdBridge.m: launchd job creation, segmentation
- SCBlockBundle.m: Bundle data model
- SCWeeklySchedule.m: Per-bundle weekly schedule
- SCTimeRange.m: Allowed window data model

**Common Layer (Common/):**
- SCSettings.m: Settings
- SCXPCClient.m: XPC client
- SCStartupSafetyCheck.m: Startup safety test (runs on version change)
- Utility/SCBlockUtilities.m: Block state
- Utility/SCHelperToolUtilities.m: Privileged ops
- Utility/SCVersionTracker.m: Version tracking for safety check

**CLI:** cli-main.m

## Key Concepts

1. **Dual-layer blocking:** /etc/hosts + PF firewall
2. **Privilege separation:** App (user) -> XPC -> Daemon (root)
3. **Persistence:** Settings in /usr/local/etc/.{hash}.plist
4. **Continuous verification:** 1-second checkup timer
5. **Timezone-rigid design:** Blocks use UTC timestamps for anti-circumvention. See [TIMEZONE_HANDLING.md](TIMEZONE_HANDLING.md)

## Adding Features

**New block type:**
1. SCBlockEntry.m - new property
2. BlockManager.m - handle entry type
3. New Blocker class
4. SCDaemonBlockMethods.m - add to checkup
5. DomainListWindowController.m - UI

**New XPC method:**
1. SCDaemonProtocol.h - define
2. SCDaemonXPC.m - implement (daemon)
3. SCXPCClient.m - client method
4. AppController.m - call

**New setting:**
1. SCSettings.m - key + accessors
2. UI control
3. Daemon handler if needed

## Debug Commands

```bash
# Check hosts
cat /etc/hosts | grep SELFCONTROL

# Check PF rules
sudo pfctl -s rules -a org.eyebeam

# Check daemon
sudo launchctl list | grep selfcontrol
```

## Glossary

**System terms:** PF=Packet Filter, pfctl=PF CLI, XPC=IPC mechanism, SMJobBless=privileged helper install, Anchor=PF sub-ruleset, Checkup=periodic block verification

**Scheduling terms:** See [dictionary.md](dictionary.md) for full definitions of: Editor, Allowed Window, Block Window, Segment, Merged Blocklist, Committed State, Pre-Authorized Schedule, Bundle, Entry, Week Offset
