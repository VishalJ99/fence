# Daemon Update Lifecycle

This document describes how the privileged daemon (`selfcontrold`) gets updated when the app is updated via Sparkle.

## Overview

The daemon is installed via `SMJobBless` to
`/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold`. The current app runs
a protocol-and-capability handshake after launch and repairs a missing,
unreachable, or incompatible helper once. Marketing-version ordering is not
the authority.

PER-383 removes ordinary schedule commit as an installation trigger. A V2
commit requires daemon protocol 5 plus `root-schedule-store-v2` and
`root-schedule-timer-v1`; if the launch-time repair did not produce that
contract, the commit fails closed instead of writing partial state. Manual
block installation retains its existing explicit helper-install flow.

## Update Triggers

```mermaid
flowchart TB
    subgraph Triggers["Daemon Update Triggers"]
        T1[App launch handshake finds helper missing/unreachable/incompatible]
        T2[User starts manual block]
    end

    subgraph NoUpdate["Does NOT Trigger Update"]
        N1[Compatible V2 schedule commit]
        N2[Root scheduler boundary fires]
        N3[Legacy V1 CLI executes]
    end

    subgraph Update["Daemon Update Flow"]
        U1[installDaemon: called]
        U2[SMJobRemove - kill old daemon]
        U3[SMJobBless - install new daemon]
        U4[New daemon running ✓]
    end

    T1 --> U1
    T2 --> U1
    U1 --> U2
    U2 --> U3
    U3 --> U4

    N1 -.->|Uses existing daemon| X[No update]
    N2 -.->|Existing daemon evaluates| X
    N3 -.->|Just XPC call| X
```

## App Launch Flow

```mermaid
flowchart TB
    A[App Launches] --> C[Wait 0.5s]
    C --> D[XPC: getCompatibilityInfo]
    D --> E{Protocol + required capabilities compatible?}

    E -->|NO / unreachable| F[One debounced reinstallDaemon attempt]
    F --> G[SMJobRemove]
    G --> H[SMJobBless]
    H --> I[New daemon installed ✓]

    E -->|YES| J[Use existing daemon]
    I --> K[Reconnect and repeat handshake once]
    K --> L{Compatible now?}
    L -->|yes| J
    L -->|no| M[Report typed incompatibility; V2 commit remains blocked]

    style F fill:#ff9999
    style I fill:#99ff99
    style M fill:#ffff99
```

## Sparkle Update Scenario

```mermaid
sequenceDiagram
    participant U as User
    participant S as Sparkle
    participant App as Fence.app
    participant D as Daemon

    U->>S: Check for updates
    S->>S: Download new Fence.app
    S->>App: Relaunch app
    App->>D: getCompatibilityInfo
    D-->>App: protocol, build, marketing version, capabilities
    alt Compatible contract
        App->>App: Keep installed helper
    else Missing, unreachable, or incompatible
        App->>D: One SMJobRemove + SMJobBless repair
        App->>D: Reconnect and repeat handshake
        D-->>App: Compatible contract or typed failure
    end

    Note over U,D: Later: user commits a V2 schedule
    U->>App: Click "Commit"
    App->>D: Verify root-scheduler compatibility
    App->>D: Authenticated owner/week batch
    Note over D: No ordinary reinstall and no per-segment LaunchAgent
```

## Legacy V1 LaunchAgent Flow (No Daemon Update)

> This section records rollback/drain behavior for already-installed V1 jobs.
> New V2 commitments have no user LaunchAgent or CLI boundary process.

```mermaid
flowchart TB
    subgraph Launchd["Launchd Job Fires"]
        L1[StartCalendarInterval triggers]
        L2[Execute selfcontrol-cli]
    end

    subgraph CLI["CLI Execution"]
        C1[Parse --schedule-id, --startdate, --enddate]
        C2[Validate dates]
        C3[Connect to daemon via XPC]
        C4[Call startScheduledBlockWithID:]
    end

    subgraph Daemon["Existing Daemon"]
        D1[Receive XPC call]
        D2[Start block with settings from ApprovedSchedules]
    end

    L1 --> L2
    L2 --> C1
    C1 --> C2
    C2 --> C3
    C3 --> C4
    C4 --> D1
    D1 --> D2

    Note1[CLI talks to EXISTING daemon]
    Note2[No SMJobBless called]
    Note3[Daemon version unchanged]

    style Note1 fill:#ffff99
    style Note2 fill:#ffff99
    style Note3 fill:#ffff99
```

## Compatibility Authority

Both app and daemon still expose release/build metadata, but it is diagnostic
only. `AppController` and `SCXPCClient` gate behavior on the monotonic daemon
protocol plus named capabilities. This avoids the retained-helper case where a
numerically newer historical marketing version lacks selectors required by a
newer Fence app.

For PER-383 the root-schedule write requires:

- `SCDaemonProtocolVersionRootScheduler` (protocol 5 or newer);
- `root-schedule-store-v2`; and
- `root-schedule-timer-v1`.

The app performs at most one debounced repair attempt, reconnects, and repeats
the handshake. It does not assume that `SMJobBless` success means the new
contract is usable.

## Key Files

| File | Purpose |
|------|---------|
| `Common/SCXPCClient.m` | `installDaemon:` method with SMJobBless |
| `Common/SCXPCClient.m` | Protocol/capability predicates and root-schedule gate |
| `AppController.m` | Launch-time compatibility check and single repair attempt |
| `Daemon/SCDaemonProtocol.h` | Monotonic protocol and capability names |
| `Daemon/SCDaemonXPC.m` | Compatibility reply and V2 batch implementation |

## Log Messages

When the app launches, look for these log messages:

```
# App launch → compatibility check always runs
AppController: Checking daemon protocol capabilities in 0.5s...
AppController: Daemon compatible (protocol=5, build=..., marketing=...)

# Missing selector/capability → one repair
AppController: Daemon incompatible (reason=..., protocol=..., build=..., marketing=...)
Attempting to reinstall daemon...

# Repair is not trusted without a post-repair handshake
Refreshing helper tool connection and verifying compatibility once...
```

## Summary

| Event | Daemon Updated? | Why |
|-------|-----------------|-----|
| App launches | Only if needed | Protocol/capability handshake repairs once when missing, unreachable, or incompatible |
| User commits V2 schedule | ❌ No in ordinary flow | Compatible helper receives one authenticated root-store batch |
| User starts manual block | ✅ Yes | `installDaemon:` called |
| Root scheduler boundary fires | ❌ No | Existing daemon evaluates its root store |
| Legacy V1 LaunchAgent fires | ❌ No | CLI just connects to existing daemon |

**Failure behavior:** If the post-repair contract is still incompatible, V2
commitment creation fails before mutation. Existing root-owned records remain
available to the installed daemon; no partial per-segment write is attempted.

---

*Last updated: July 2026 (PER-383)*
