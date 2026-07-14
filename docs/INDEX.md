# Fence Documentation Index

## Quick Lookup

| Task | Doc | Files |
|------|-----|-------|
| Architecture | [SYSTEM_ARCHITECTURE.md](../SYSTEM_ARCHITECTURE.md) | - |
| Blocking | [BLOCKING_MECHANISM.md](BLOCKING_MECHANISM.md) | BlockManager.m, PacketFilter.m, HostFileBlocker.m |
| App blocking | [BLOCKING_MECHANISM.md#app-blocking](BLOCKING_MECHANISM.md#app-blocking-implementation) | AppBlocker.m, SCBlockEntry.m |
| Safety/Robustness | [BLOCK_SAFETY_ANALYSIS.md](BLOCK_SAFETY_ANALYSIS.md) | SCStartupSafetyCheck.m, emergency.sh |
| Scheduling | [dictionary.md](dictionary.md) | SCScheduleManager.m, SCDaemonScheduler.m |
| Schedule job lifecycle | [SCHEDULE_JOB_LIFECYCLE.md](SCHEDULE_JOB_LIFECYCLE.md) | SCScheduleManager.m, SCDaemonXPC.m, SCDaemonScheduler.m |
| **Daemon Lifecycle** | [DAEMON_LIFECYCLE.md](DAEMON_LIFECYCLE.md) | SCDaemon.m, SCDaemonScheduler.m, org.eyebeam.selfcontrold.plist |
| **Daemon Update Lifecycle** | [DAEMON_UPDATE_LIFECYCLE.md](DAEMON_UPDATE_LIFECYCLE.md) | AppController.m, SCXPCClient.m, SCDaemonProtocol.h |
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
        App[Fence.app] --> XPC
        CLI[selfcontrol-cli - V1 compatibility] --> XPC
    end
    subgraph Root[Privileged - root]
        XPC --> Daemon[selfcontrold]
        Daemon --> Scheduler[SCDaemonScheduler]
        Daemon --> Commitments[(Immutable V2 commitment envelopes)]
        Daemon --> Store[(Root V1/V2 ApprovedSchedules)]
        Store --> Scheduler
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
- SCDaemon.m: Lifecycle, XPC listener, scheduler event wiring
- SCDaemonScheduler.m: Root V1/V2 selection, exact boundary timer, 60s backstop
- SCDaemonXPC.m: XPC handler, authenticated atomic owner/week store
- SCDaemonBlockMethods.m: Block operations and active provenance

**Blocking Layer (Block Management/):**
- BlockManager.m: Orchestrator
- HostFileBlocker.m: /etc/hosts
- PacketFilter.m: PF rules
- AppBlocker.m: Process killer
- SCBlockEntry.m: Entry model

**Scheduling Layer (Block Management/):**
- SCScheduleManager.m: Bundle/schedule orchestrator
- SCScheduleLaunchdBridge.m: segment calculation support and V1 LaunchAgent compatibility
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

1. **Triple-layer blocking:** /etc/hosts + PF firewall + app-process enforcement
2. **Privilege separation:** App (user) -> XPC -> Daemon (root)
3. **Root schedule authority:** New V2 commitments are atomic
   owner/absolute-week envelopes plus records timed by `selfcontrold`; user
   LaunchAgents and the CLI are V1 rollback/drain only
4. **Immutable admission:** A root envelope exists even for a zero-segment
   week; exact same-batch identity/content retries are idempotent and any different
   unexpired absolute overlap (including V1) is rejected
5. **Persistence:** Settings in /usr/local/etc/.{hash}.plist
6. **Continuous verification:** 1-second checkup timer
7. **Timezone-rigid design:** Blocks use absolute timestamps for anti-circumvention. See [TIMEZONE_HANDLING.md](TIMEZONE_HANDLING.md)

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

**Scheduling terms:** See [dictionary.md](dictionary.md) for full definitions of: Editor, Allowed Window, Block Window, Segment, Merged Blocklist, Committed State, Pre-Authorized Schedule, Root-Owned Schedule, Bundle, Entry, Week Offset
