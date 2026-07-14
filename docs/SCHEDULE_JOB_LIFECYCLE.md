# Schedule Job Lifecycle

This document describes the complete lifecycle of committed schedule segments,
from user input to cleanup. New commitments use the V2 root scheduler. The
older per-segment LaunchAgent lifecycle is retained below as a compatibility
reference for draining V1 commitments.

> **Note:** For timezone handling and travel scenarios, see [TIMEZONE_HANDLING.md](TIMEZONE_HANDLING.md).
>
> **Note:** For daemon timers, persistence, and sleep/wake behavior, see [DAEMON_LIFECYCLE.md](DAEMON_LIFECYCLE.md).

## Current V2 Lifecycle (PER-383)

```mermaid
flowchart TD
    A[User commits current or next week] --> B[SCScheduleManager computes absolute segments]
    B --> C[Preserve existing one-minute inter-segment gap]
    C --> D[One authenticated owner/week batch over XPC]
    D --> E{Validate batch + absolute overlap}
    E -->|same identity + records| F[Idempotent success]
    E -->|different unexpired overlap or invalid| G[Reject without changing root store]
    E -->|new non-overlapping commitment| H[Persist immutable envelope + zero or more segments]
    H --> I[Verify identity in SCSettings post-sync view]
    F --> J[SCDaemonScheduler recomputes desired record]
    I --> J
    J --> K{Desired half-open window active?}
    K -->|yes, idle| L[Apply block and save local provenance]
    K -->|no| M[Arm next wall-clock boundary]
    K -->|manual/test active| N[Defer]
    K -->|different schedule active| O[Defer active-to-active mutation]
    L --> M
    N --> M
    O --> M
```

The V2 authority chain is intentionally short:

1. `SCScheduleManager` compiles the weekly UI model into zero or more
   non-overlapping absolute segments. Segment end dates retain the existing
   one-minute compatibility gap. Even a zero-segment week is a commitment.
2. `SCXPCClient` requires daemon protocol 5 and the
   `root-schedule-store-v2` / `root-schedule-timer-v1` capabilities. Helper
   repair belongs to this compatibility handshake; an ordinary commit does
   not reinstall the daemon.
3. `SCDaemonXPC` authenticates the caller and derives the owner from the audit
   token. An exact stored batch with matching commitment+generation and records
   is an idempotent retry. A
   different batch is rejected when its absolute week overlaps an unexpired
   commitment envelope or schedule record (including V1) for that owner, even
   if its local `weekKey` changed after travel. The legacy V1 registration
   selector applies the reciprocal guard: it rejects a requested segment that
   overlaps an unexpired V2 commitment envelope.
4. For a new admissible batch, the daemon persists one immutable
   `ApprovedScheduleCommitments` envelope plus zero or more
   `ApprovedSchedules` records. It verifies the envelope and every validated
   record field in SCSettings' post-sync view before reporting success; this is
   not an independent raw-disk reread.
5. `SCDaemonScheduler` serializes evaluation and applies the desired record
   through `SCDaemonBlockMethods`. The app stores a local V2 manifest only to
   map its bundle/week model to root records for strictify and diagnostics.

New V2 commits create **no** `~/Library/LaunchAgents` plist and do not invoke
`selfcontrol-cli` at a segment boundary.

The root envelope is also the commitment-lock authority when app-local state is
missing or a timezone change maps the same absolute interval to a different
week key. Loss of `SCWeekCommitment_*` / `SCScheduleManifest_*` can make the UI
need repair, but it cannot authorize a different overlapping root batch.

### Reconciliation Triggers

| Trigger | Purpose |
|---|---|
| Daemon startup | Rebuild desired state after boot, crash, or helper restart |
| Exact wall-clock boundary | Prompt start/end at the next absolute record boundary |
| Wake | Catch boundaries crossed while asleep |
| Clock or timezone change | Recompute from absolute dates after wall-time changes |
| Store mutation | Apply a newly admitted commitment immediately |
| Active-block completion | Select the next eligible record after teardown |
| 60-second backstop | Recover from a missed/coalesced notification or timer |

The timer is a promptness mechanism, not the authority. Every trigger reloads
root records and derives desired state using half-open bounds
`approvedStartDate <= now < approvedEndDate`.

### Arbitration and Transition Safety

- Manual and safety-test blocks win while active. The scheduler defers and
  retries at later triggers rather than replacing them.
- A V2 mutation that changes the desired record while another schedule-owned
  policy is active also defers. The cutover does not perform remove-then-add.
- Before treating an active schedule as already correct, the daemon compares
  owner/source and schedule identity; for V2 it also compares
  commitment/generation and policy revision, plus allowlist mode and canonical
  content. A matching denylist may be stricter than the stored policy, but it
  may not be weaker.
- The current one-minute gap between adjacent computed segments remains.
  Eliminating it requires a separate PF/hosts/AppBlocker primitive that stages
  the replacement before obsolete rules are dropped.
- Active provenance (`manual`, `test`, `legacy_schedule`, or `scheduler_v2`)
  plus schedule/revision/generation identifiers is stored only in root
  settings. It is used for idempotency and local comparison, not uploaded.

### V2 Strictify and Diagnostics

Live strictify remains monotonic. The app uses its local V2 manifest to map
bundle additions to root records, and the daemon verifies record persistence.
If one of those records is the currently active schedule, the daemon holds the
same mutation lock across active physical append/verification and the future
root-record update. It persists the stricter future record only after hosts,
PF, required app-process enforcement, and active settings verify. A retry of an
already-unioned active list still re-exercises the physical layers instead of
trusting settings alone. LaunchAgent load/probe checks are performed only for
V1 records because a V2 record deliberately has no user job.

The same backend distinction applies to startup consistency and support
snapshots:

- V2: compare app projection → root record → active provenance/physical layers.
- V1: additionally validate the plist and loaded launchd job.

Remote telemetry receives typed aggregate outcomes only. IDs, dates, UIDs,
bundle IDs, revisions, entries, and settings values remain local.

### Destructive Test Boundary

The legacy bulk-clear XPC selector is not a release recovery mechanism. Release
builds reject it even after authorization. DEBUG builds retain it for tests and
clear `ApprovedSchedules` plus `ApprovedScheduleCommitments` in the same
locked, persisted mutation. Per-record cleanup otherwise removes only expired
owner records/envelopes; a live V2 record cannot be unregistered through the
legacy selector.

## Legacy V1 Compatibility Lifecycle

> The remainder of this document describes the pre-PER-383 LaunchAgent path.
> Existing V1 approvals/jobs are supported only for bounded current/next-week
> rollback and drain. Their redundant LaunchAgent/CLI trigger still works, but
> V1 daemon recovery now comes from the same root-record scheduler described
> above; the historical plist-scanning recovery diagrams below no longer run.
> An unexpired V1 record blocks admission of an overlapping V2 commitment.

### Legacy V1 Overview Diagram

```mermaid
flowchart TB
    subgraph UI["User Interface"]
        A[User defines bundles & schedules]
        B[User clicks 'Commit Week']
    end

    subgraph Commit["Commit Flow (SCScheduleManager)"]
        C[commitToWeekWithOffset:]
        D[Cleanup stale jobs<br/>endDate in past]
        E[Calculate merged segments]
        F[Generate unique segmentID<br/>per segment]
    end

    subgraph Registration["Job Registration"]
        G[Register in ApprovedSchedules<br/>via XPC to daemon]
        H[Create launchd plist<br/>with startDate + endDate]
        I[Load job via launchctl]
    end

    subgraph Storage["Persisted State"]
        J[(ApprovedSchedules<br/>in daemon settings<br/>/usr/local/etc/.hash.plist)]
        K[(Launchd Plist<br/>~/Library/LaunchAgents/<br/>org.eyebeam...merged-UUID...plist)]
    end

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    F --> H
    G --> J
    H --> I
    I --> K
```

### Legacy V1 Job Firing Paths

There were **three paths** that could trigger a V1 scheduled block:

| Path | Trigger | Use Case |
|------|---------|----------|
| **Path 1** | launchd fires at scheduled time | Normal operation |
| **Path 2** | Daemon startup | Reboot during scheduled window |
| **Path 3** | Periodic daemon sweep (1 min) | Sleep/wake, launchd failures, background permission disabled |

```mermaid
flowchart TB
    subgraph Trigger["Job Trigger"]
        T1[launchd fires at<br/>StartCalendarInterval<br/>day + time]
        T2[System reboot<br/>during scheduled block]
        T3[Daemon sweep timer<br/>fires every 1 minute]
    end

    subgraph Path1["Path 1: Launchd → CLI → Daemon"]
        P1A[launchd executes CLI:<br/>selfcontrol-cli start<br/>--schedule-id=UUID<br/>--startdate=...<br/>--enddate=...]
        P1B{CLI: Parse dates<br/>from args}
        P1C{now < startDate?}
        P1D{now > endDate?}
        P1E[XPC: cleanupStaleSchedule]
        P1F[XPC: startScheduledBlockWithID]
        P1G[Skip - future week]
    end

    subgraph Path2["Path 2: Daemon Startup Recovery"]
        P2A[Daemon starts:<br/>startMissedBlockIfNeeded]
        P2B[Scan plist files in<br/>~/Library/LaunchAgents/]
        P2C[Parse startDate + endDate<br/>from plist ProgramArguments]
        P2D{now < startDate?}
        P2E{now > endDate?}
        P2F[cleanupStaleScheduleWithID]
        P2G[SCDaemonBlockMethods<br/>startBlock directly]
        P2H[Skip - future week]
    end

    subgraph Path3["Path 3: Periodic Daemon Sweep"]
        P3A[scheduleCheckTimer fires<br/>every 60 seconds]
        P3B[startMissedBlockIfNeeded]
        P3C{Block already<br/>running?}
        P3D[Exit early]
        P3E[Same as Path 2:<br/>Scan + validate + start]
    end

    subgraph Daemon["Daemon Block Execution"]
        D1[Lookup ApprovedSchedules<br/>by segmentID]
        D2[Extract blocklist +<br/>block settings]
        D3[SCDaemonBlockMethods<br/>startBlockWithControllingUID]
        D4[Install PF rules<br/>+ /etc/hosts<br/>+ AppBlocker]
        D5[Start checkup timer<br/>1-second interval]
    end

    T1 --> P1A
    P1A --> P1B
    P1B --> P1C
    P1C -->|Yes| P1G
    P1C -->|No| P1D
    P1D -->|Yes| P1E
    P1D -->|No| P1F
    P1E --> Cleanup
    P1F --> D1

    T2 --> P2A
    P2A --> P2B
    P2B --> P2C
    P2C --> P2D
    P2D -->|Yes| P2H
    P2D -->|No| P2E
    P2E -->|Yes| P2F
    P2E -->|No| P2G
    P2F --> Cleanup
    P2G --> D4

    T3 --> P3A
    P3A --> P3B
    P3B --> P3C
    P3C -->|Yes| P3D
    P3C -->|No| P3E
    P3E --> D4

    D1 --> D2
    D2 --> D3
    D3 --> D4
    D4 --> D5
```

#### Path 3: Why the Legacy Periodic Sweep Existed

The pre-PER-383 1-minute periodic sweep existed as a **backup mechanism** for cases where launchd (Path 1) failed. V2 keeps a 60-second backstop but reads the root store directly and never scans a V2 LaunchAgent:

| Scenario | launchd Behavior | Path 3 Saves the Day |
|----------|------------------|----------------------|
| **Sleep/wake** | May not fire jobs during sleep | Sweep catches it within 60s of wake |
| **Background permission disabled** | Jobs not loaded | Sweep bypasses launchd entirely |
| **launchd edge cases** | Rare timing issues | Sweep provides redundancy |

**Race condition safety:** The sweep always checks `anyBlockIsRunning` first. If launchd already started the block, the sweep exits early. Both paths can fire — only one will actually start the block.

## Block Lifecycle & Expiration

```mermaid
flowchart TB
    subgraph Active["Active Block"]
        A1[Block running<br/>BlockIsRunning = YES]
        A2[Checkup timer<br/>every 1 second]
        A3{Block expired?<br/>now > endDate}
        A4{Block tampered?<br/>rules missing}
        A5[Re-add rules<br/>checkBlockIntegrity]
    end

    subgraph End["Block End"]
        E1[removeBlock]
        E2[Clear PF rules]
        E3[Restore /etc/hosts]
        E4[Stop AppBlocker]
        E5[BlockIsRunning = NO]
        E6[Stop checkup timer]
    end

    A1 --> A2
    A2 --> A3
    A3 -->|No| A4
    A4 -->|Yes| A5
    A5 --> A2
    A4 -->|No| A2
    A3 -->|Yes| E1
    E1 --> E2
    E2 --> E3
    E3 --> E4
    E4 --> E5
    E5 --> E6
```

## Live Blocklist Updates (Strictify)

While a block is running, users can **add** items to bundles and have them take effect immediately. This is called "live strictify" — the block can only get **stricter**, never looser.

### Monotonic Security Constraint

| Action | Allowed? | Behavior |
|--------|----------|----------|
| **Add** item to bundle | ✅ Yes | Immediately blocked |
| **Remove** item from bundle | ❌ No | Silently ignored, logged as warning |

This prevents users from bypassing blocks by removing entries mid-session.

### Update Flow Diagram

```mermaid
sequenceDiagram
    participant UI as Frontend<br/>(SCScheduleManager)
    participant XPC as XPC Client
    participant D as Daemon mutation lock
    participant BM as BlockManager
    participant Store as Root ApprovedSchedules

    Note over UI: User edits bundle<br/>(adds twitter.com)
    UI->>UI: Preserve removals; canonicalize additions
    par Active path when expected
        UI->>XPC: appendEntriesToActiveBlocklist + exact old list
        XPC->>D: Owner/precondition-checked request
        D->>BM: Append hosts/PF/apps and verify physical result
        D->>D: Persist and verify stricter ActiveBlocklist
    and Current/future approval path
        UI->>XPC: appendEntriesToApprovedSchedules + expected lists
        XPC->>D: Match owner, schedule, mode, and exact content
        alt Candidate is the active scheduled record
            D->>BM: Physically apply and verify additions first
        end
        D->>Store: Persist and verify stricter matching records
        D->>D: Probe loaded jobs only for V1 candidates
    end
    XPC-->>UI: Typed aggregate results
    UI->>UI: Emit one block.strictify_result outcome
```

Both daemon requests use the shared mutation lock, exact preconditions, and
retry-safe union handling. In particular, the approval path cannot persist a
stricter currently-active schedule while physical enforcement remains weaker:
it applies and verifies the additions before writing that root record. A retry
that sees the exact union in settings re-applies the physical layers rather
than assuming settings are proof of enforcement.

For scheduler reconciliation, an active V2 record matches only when
schedule/owner provenance, commitment, generation, policy revision, mode, and
content agree. Denylist enforcement may contain extra entries (strictification)
but cannot omit any record entry. LaunchAgent verification applies only to V1
candidates; V2 has no user job.

### Key Source Files

| File | Method | Purpose |
|------|--------|---------|
| `Block Management/SCScheduleManager.m` | `updateBundle:` / strictify orchestration | Preserves removals, resolves active/future candidates, aggregates telemetry |
| `Common/SCXPCClient.m` | Structured append wrappers | Sends active and root-record updates |
| `Daemon/SCDaemonXPC.m` | `appendEntriesToApprovedSchedules:...` | Lock-scoped record matching, active coupling, persistence, V1-only job probes |
| `Daemon/SCDaemonBlockMethods.m` | `appendEntriesToActiveBlocklistWhileHoldingDaemonLock:...` | Canonical append, physical apply, settings persistence, postcondition verification |
| `Daemon/SCDaemonScheduler.m` | `activeState:matchesRecord:` | Full provenance/mode/content match before a verified no-op |

## Cleanup Mechanisms

There are **two types of cleanup** for different scenarios:

| Cleanup Type | Purpose | What it clears |
|--------------|---------|----------------|
| `cleanupStaleScheduleWithID:` | Remove expired **job definition** | launchd plist + ApprovedSchedules entry |
| `clearExpiredBlockWithReply:` | Remove expired **blocking rules** | PF rules + /etc/hosts + AppBlocker + BlockIsRunning flag |

### Job Cleanup (cleanupStaleScheduleWithID)

Used when a scheduled job's `endDate` has passed - removes the job definition.

```mermaid
flowchart TB
    subgraph Triggers["Job Cleanup Triggers"]
        T1[CLI detects<br/>job endDate passed]
        T2[Daemon startup detects<br/>job endDate passed]
        T3[Commit flow detects<br/>stale jobs]
    end

    subgraph Cleanup["cleanupStaleScheduleWithID:"]
        C1[Remove from<br/>ApprovedSchedules]
        C2[Find plist matching<br/>merged-UUID pattern]
        C3[launchctl bootout<br/>unload job]
        C4[Delete plist file]
    end

    subgraph Result["Result"]
        R1[Job no longer fires]
        R2[ApprovedSchedules<br/>entry removed]
        R3[Resources freed]
    end

    T1 --> Cleanup
    T2 --> Cleanup
    T3 --> Cleanup

    C1 --> C2
    C2 --> C3
    C3 --> C4
    C4 --> R1
    C4 --> R2
    C4 --> R3
```

### Block Cleanup (clearExpiredBlockWithReply)

Used when an active block has expired but wasn't cleared (e.g., after sleep/wake when checkup timer couldn't run).

```mermaid
flowchart TB
    subgraph Trigger["Block Cleanup Trigger"]
        T1[CLI detects:<br/>anyBlockIsRunning=YES<br/>AND currentBlockIsExpired=YES]
    end

    subgraph Cleanup["clearExpiredBlockWithReply:"]
        C1[Verify block is<br/>actually expired]
        C2[Clear PF firewall rules]
        C3[Restore /etc/hosts]
        C4[Stop AppBlocker]
        C5[Set BlockIsRunning=NO]
        C6[Send config notification]
    end

    subgraph Result["Result"]
        R1[Blocking infrastructure<br/>removed]
        R2[New block can<br/>start cleanly]
    end

    T1 --> C1
    C1 --> C2
    C2 --> C3
    C3 --> C4
    C4 --> C5
    C5 --> C6
    C6 --> R1
    C6 --> R2
```

**Sleep/Wake Scenario:**
1. Block runs from 9:00-10:00
2. User closes laptop at 9:30 (sleep)
3. At 10:00, block should expire, but checkup timer is suspended
4. At 11:00, next scheduled block tries to start
5. CLI detects: `anyBlockIsRunning=YES` but `currentBlockIsExpired=YES`
6. CLI calls `clearExpiredBlock` to clear stale blocking rules
7. New block starts successfully

## Data Structures

### Launchd Plist (Job Definition)

```
~/Library/LaunchAgents/org.eyebeam.selfcontrol.schedule.merged-{UUID}.{day}.{time}.plist
```

```xml
<dict>
    <key>Label</key>
    <string>org.eyebeam.selfcontrol.schedule.merged-550e8400-e29b-41d4.tuesday.0930</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli</string>
        <string>start</string>
        <string>--schedule-id=550e8400-e29b-41d4</string>
        <string>--startdate=2026-01-06T09:30:00Z</string>
        <string>--enddate=2026-01-06T17:00:00Z</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>2</integer>
        <key>Hour</key><integer>9</integer>
        <key>Minute</key><integer>30</integer>
    </dict>

    <key>RunAtLoad</key><false/>
</dict>
```

### ApprovedSchedules Entry

```
/usr/local/etc/.{hash}.plist → ApprovedSchedules dictionary
```

```objc
ApprovedSchedules[@"550e8400-e29b-41d4"] = @{
    @"blocklist": @[@"facebook.com", @"app:com.apple.Terminal"],
    @"isAllowlist": @NO,
    @"blockSettings": @{
        @"ClearCaches": @YES,
        @"AllowLocalNetworks": @NO
    },
    @"controllingUID": @501,
    @"registeredAt": <NSDate>
};
```

## Validation Logic

```mermaid
flowchart LR
    subgraph Input["Job Fires"]
        I1[startDate]
        I2[endDate]
        I3[now = current time]
    end

    subgraph Check["Validation"]
        C1{now < startDate?}
        C2{now > endDate?}
    end

    subgraph Action["Action"]
        A1[SKIP<br/>Future week<br/>Don't cleanup]
        A2[CLEANUP<br/>Expired job<br/>Remove everything]
        A3[EXECUTE<br/>Valid job<br/>Start block]
    end

    I1 --> C1
    I2 --> C2
    I3 --> C1
    I3 --> C2

    C1 -->|Yes| A1
    C1 -->|No| C2
    C2 -->|Yes| A2
    C2 -->|No| A3
```

## Multi-Week Commit Scenario (Sunday)

```mermaid
sequenceDiagram
    participant U as User
    participant SM as SCScheduleManager
    participant LB as LaunchdBridge
    participant D as Daemon
    participant L as Launchd

    Note over U: It's Sunday Jan 5

    U->>SM: Commit This Week
    SM->>SM: Cleanup stale jobs (none)
    SM->>LB: Create segments for This Week
    LB->>D: Register ApprovedSchedules[UUID-A]
    LB->>L: Install job UUID-A<br/>Sunday 2pm-6pm<br/>startDate=Jan 5 2pm<br/>endDate=Jan 5 6pm

    U->>SM: Commit Next Week
    SM->>SM: Cleanup stale jobs (none - This Week still valid)
    SM->>LB: Create segments for Next Week
    LB->>D: Register ApprovedSchedules[UUID-B]
    LB->>L: Install job UUID-B<br/>Sunday 2pm-6pm<br/>startDate=Jan 12 2pm<br/>endDate=Jan 12 6pm

    Note over L: Sunday Jan 5, 2pm arrives

    L->>L: Fire UUID-A job
    L->>L: Fire UUID-B job (same day/time!)

    Note over L: UUID-A: startDate=Jan 5 ✓
    Note over L: UUID-B: startDate=Jan 12 ✗ (future)

    L-->>D: UUID-A proceeds → Block starts
    L-->>D: UUID-B skips (now < startDate)
```

## Key Files

| File | Purpose |
|------|---------|
| `Block Management/SCScheduleManager.m` | Commit flow, segment calculation, cleanup orchestration, **live strictify trigger** |
| `Common/SCXPCClient.m` | V2 compatibility gate and authenticated owner/week batch |
| `Daemon/SCDaemonScheduler.m` | V2 desired-state selection, boundary timer, backstop, and serialized reconciliation |
| `Block Management/SCScheduleLaunchdBridge.m` | V1 plist creation/cleanup compatibility only |
| `Block Management/BlockManager.m` | Block installation, **append mode for live updates** |
| `Block Management/PacketFilter.m` | PF rule management, **append mode for live updates** |
| `cli-main.m` | V1 compatibility arg parsing, validation, and XPC calls |
| `Daemon/SCDaemon.m` | Scheduler construction and startup/wake/clock/timezone triggers |
| `Daemon/SCDaemonXPC.m` | Atomic V2 store, V1 bridge, strictify, diagnostics, and cleanup |
| `Daemon/SCDaemonBlockMethods.m` | Actual block execution, checkup timer, **monotonic update enforcement** |
| `Common/SCSentry.m` | Typed schedule/strictify telemetry schemas and privacy tripwire |

---

*Last updated: July 2026 (PER-383)*
