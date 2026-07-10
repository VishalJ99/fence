# Fence System Architecture

> **Version:** 3.4.7 (Build 647; historical targets still use SelfControl names)
> **Purpose:** Comprehensive technical documentation for developers and AI agents
> **Last Updated:** July 2026

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Component Deep Dive](#3-component-deep-dive)
4. [Blocking Mechanism](#4-blocking-mechanism)
5. [App Blocking (NEW)](#5-app-blocking-new)
6. [Data Flow Diagrams](#6-data-flow-diagrams)
7. [Module Reference](#7-module-reference)
8. [Security Model](#8-security-model)
9. [Debug Features](#6-debug-features)
10. [Quick Reference](#10-quick-reference)

---

## 1. Executive Summary

Fence is a macOS application that blocks selected websites, network resources, and apps for committed schedule windows. **The block cannot be disabled** until the timer expires—even restarting the computer won't help.

### Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Triple-layer blocking** | /etc/hosts + PF firewall + App killer provides redundancy |
| **Privileged daemon** | Root access needed for system files; separated from UI |
| **XPC communication** | Secure IPC between unprivileged app and root daemon |
| **Continuous verification** | 1-second checkup timer ensures block persists |
| **Settings in /usr/local/etc** | Survives app deletion; requires root to modify |
| **App blocking via process kill** | Polls running apps every 500ms, kills blocked ones |
| **Privacy-safe remote diagnostics** | Typed app events plus a root-owned, consent-gated daemon spool; raw entries never leave the machine |

### Technology Stack

- **Language:** Objective-C
- **Frameworks:** Cocoa, Security.framework, ServiceManagement
- **IPC:** XPC (Mach message-based)
- **Firewall:** macOS Packet Filter (PF/pf.conf)
- **DNS Override:** /etc/hosts modification
- **Diagnostics:** Sentry in the app only; daemon records move through authenticated XPC

---

## 2. High-Level Architecture

### 2.1 System Overview

```mermaid
graph TB
    subgraph "User Space"
        APP[Fence.app<br/>Bundle: org.eyebeam.Fence]
        CLI[selfcontrol-cli<br/>Command Line Tool]
    end

    subgraph "Privileged Space (root)"
        DAEMON[selfcontrold<br/>LaunchDaemon]
    end

    subgraph "System Resources"
        HOSTS[/etc/hosts]
        PF[/etc/pf.conf<br/>+ /etc/pf.anchors/org.eyebeam]
        SETTINGS[/usr/local/etc/.{hash}.plist]
        LAUNCHD[launchd]
    end

    APP -->|XPC| DAEMON
    CLI -->|XPC| DAEMON
    DAEMON -->|Modify| HOSTS
    DAEMON -->|pfctl| PF
    DAEMON -->|Read/Write| SETTINGS
    LAUNCHD -->|Manages| DAEMON

    style DAEMON fill:#ff6b6b,color:#fff
    style HOSTS fill:#4ecdc4,color:#fff
    style PF fill:#4ecdc4,color:#fff
```

### 2.2 Process Relationships

```mermaid
graph LR
    subgraph "Application Layer"
        A[SelfControl.app]
        B[selfcontrol-cli]
    end

    subgraph "Service Layer"
        C[selfcontrold<br/>Privileged Daemon]
    end

    subgraph "System Layer"
        D[launchd]
        E[pfctl]
        F[DNS Resolver]
    end

    subgraph "Kernel Layer"
        G[Packet Filter]
        H[Network Stack]
    end

    A -.->|SMJobBless| D
    A -->|XPC| C
    B -->|XPC| C
    C -->|Execute| E
    C -->|Modify /etc/hosts| F
    E -->|Load Rules| G
    F -->|Override| H
    G -->|Block Packets| H
```

---

## 3. Component Deep Dive

### 3.1 Main Application (SelfControl.app)

**Purpose:** User interface for configuring and starting blocks

```mermaid
classDiagram
    class AppController {
        -TimerWindowController* timerWindowController
        -SCXPCClient* xpcClient
        -NSLock* refreshUILock
        +addBlock()
        +installBlock()
        +refreshUserInterface()
    }

    class TimerWindowController {
        -NSLock* modifyBlockLock
        +updateTimerDisplay()
        +openAddSheet()
        +openExtendSheet()
    }

    class DomainListWindowController {
        -NSMutableArray* blocklist
        +addBlocklistEntry()
        +removeBlocklistEntry()
        +importBlocklist()
    }

    class SCXPCClient {
        -NSXPCConnection* daemonConnection
        +connectToDaemon()
        +startBlock()
        +updateBlocklist()
    }

    AppController --> TimerWindowController
    AppController --> DomainListWindowController
    AppController --> SCXPCClient
```

**Key Files:**
| File | Lines | Purpose |
|------|-------|---------|
| `AppController.m` | ~806 | Main app controller, block installation |
| `TimerWindowController.m` | ~450 | Timer display, add/extend sheets |
| `DomainListWindowController.m` | ~300 | Blocklist editor table view |

### 3.2 Daemon (selfcontrold)

**Purpose:** Privileged helper that modifies system files

```mermaid
classDiagram
    class SCDaemon {
        -NSXPCListener* listener
        -NSTimer* checkupTimer
        -NSTimer* inactivityTimer
        +applicationDidFinishLaunching()
        +startCheckupTimer()
    }

    class SCDaemonXPC {
        +listener:shouldAcceptNewConnection:
        +verifyConnectionSecurity()
    }

    class SCDaemonBlockMethods {
        -NSLock* daemonMethodLock
        +startBlock()
        +updateBlocklist()
        +updateBlockEndDate()
        +checkupBlock()
    }

    class BlockManager {
        -HostFileBlockerSet* hostBlockerSet
        -PacketFilter* pf
        -NSOperationQueue* opQueue
        +prepareToAddBlock()
        +addBlockEntries()
        +finalizeBlock()
    }

    SCDaemon --> SCDaemonXPC
    SCDaemon --> SCDaemonBlockMethods
    SCDaemonBlockMethods --> BlockManager
```

**Key Files:**
| File | Lines | Purpose |
|------|-------|---------|
| `Daemon/SCDaemon.m` | ~200 | Daemon lifecycle, timers |
| `Daemon/SCDaemonBlockMethods.m` | ~388 | Block control methods |
| `Daemon/SCDaemonXPC.m` | ~150 | XPC connection handling |

### 3.3 Block Management Layer

```mermaid
classDiagram
    class BlockManager {
        +prepareToAddBlock()
        +addBlockEntriesFromStrings()
        +addBlockEntry(SCBlockEntry)
        +finalizeBlock()
    }

    class HostFileBlocker {
        -NSString* hostFileContents
        -NSLock* strLock
        +addRuleBlockingDomain()
        +writeToFileSystem()
        +revertFileContentsToDisk()
    }

    class PacketFilter {
        -NSMutableString* rules
        +addRuleWithIP:port:maskLen:
        +addAllowFooterRules()
        +startBlock()
    }

    class SCBlockEntry {
        +NSString* hostname
        +NSInteger port
        +NSInteger maskLen
        +initWithString()
    }

    BlockManager --> HostFileBlocker
    BlockManager --> PacketFilter
    BlockManager ..> SCBlockEntry
```

**Key Files:**
| File | Lines | Purpose |
|------|-------|---------|
| `Block Management/BlockManager.m` | ~531 | Orchestrates all blocking |
| `Block Management/HostFileBlocker.m` | ~250 | /etc/hosts manipulation |
| `Block Management/PacketFilter.m` | ~180 | PF rule generation |
| `Block Management/SCBlockEntry.m` | ~120 | Block entry data model |

### 3.4 Telemetry and consistency diagnostics

The app is the only process that links Sentry. `selfcontrold` never owns a
network transport: it writes privacy-validated records under
`/usr/local/etc/fence-telemetry/<uid>/`, and an audit-token-authenticated Fence
client fetches and acknowledges its own queue after explicit consent.

```mermaid
flowchart LR
    A["Fence app state"] -->|"expected projection over signed XPC"| D["selfcontrold"]
    D -->|"local exact comparisons"| R["counts, booleans, status enums"]
    D -->|"typed failure records"| Q["root-owned per-UID spool"]
    Q -->|"fetch and ack for audit-token UID"| A
    A -->|"typed sanitizer and privacy tripwire"| S["Sentry when release gates are configured"]
```

Core boundaries:

- `Common/SCSentry` owns typed schemas, consent lifecycle, SDK containment,
  and the final serialized-payload privacy tripwire.
- `Common/SCTelemetrySpool` owns locked/atomic per-UID queue storage, hard
  size/count/age bounds, consent generations, fetch/ack, and opt-out purge.
- `SCScheduleManager` builds an app-local expected active/future projection.
  `SCDaemonXPC` compares it to root settings, validated launchd plists, loaded
  jobs, and hosts/PF/app state, returning no entries, dates, labels, or IDs.
- `SCBlockApplyResult` and teardown results make physical postconditions—not
  declared settings mutation—the success authority for apply, strictify,
  integrity reapply, and cleanup.
- A corrupt/unreadable initial SCSettings file is an explicit unavailable
  state. Automatic teardown and ordinary mutation/persistence pause until a
  valid authoritative state recovers (or the narrow first-run bootstrap creates
  a genuinely missing file).

The complete privacy contract, current coverage, and production gates live in
[`docs/TELEMETRY.md`](docs/TELEMETRY.md).

---

## 4. Blocking Mechanism

### 4.1 Two-Layer Defense

SelfControl uses **two independent blocking mechanisms** for redundancy:

```mermaid
graph TB
    subgraph "Layer 1: DNS Redirect"
        A[User types facebook.com] --> B[OS checks /etc/hosts]
        B --> C{Entry exists?}
        C -->|Yes| D[Returns 0.0.0.0]
        D --> E[Connection fails locally]
        C -->|No| F[Normal DNS lookup]
    end

    subgraph "Layer 2: Packet Filter"
        G[App tries direct IP] --> H[TCP/UDP packet created]
        H --> I[PF firewall intercepts]
        I --> J{Rule matches?}
        J -->|Yes| K[Block + RST]
        J -->|No| L[Allow packet]
    end

    style D fill:#ff6b6b,color:#fff
    style K fill:#ff6b6b,color:#fff
```

### 4.2 /etc/hosts Blocking

**How it works:**
1. Backup original: `/etc/hosts` → `/etc/hosts.bak`
2. Add SelfControl block section with markers
3. For each domain: add `0.0.0.0 domain` and `:: domain`
4. DNS lookups now return localhost (connection fails)

**Example /etc/hosts modification:**
```
# Normal system entries...
127.0.0.1 localhost

# BEGIN SELFCONTROL BLOCK
0.0.0.0    facebook.com
::    facebook.com
0.0.0.0    www.facebook.com
::    www.facebook.com
0.0.0.0    twitter.com
::    twitter.com
# END SELFCONTROL BLOCK
```

### 4.3 Packet Filter (PF) Blocking

**How it works:**
1. Resolve domains to IP addresses via DNS
2. Generate PF rules for each IP
3. Write to `/etc/pf.anchors/org.eyebeam`
4. Add anchor reference to `/etc/pf.conf`
5. Execute `pfctl -f /etc/pf.conf` to load rules

**Example PF rules (blocklist mode):**
```
# Blocklist rules
block return out proto tcp from any to 157.240.1.35
block return out proto udp from any to 157.240.1.35
block return out proto tcp from any to 104.244.42.1
block return out proto udp from any to 104.244.42.1

# Always allow essential services
pass out proto udp from any to any port 53    # DNS
pass out proto udp from any to any port 123   # NTP
pass out proto udp from any to any port 67    # DHCP
pass out proto udp from any to any port 68    # DHCP
pass out proto udp from any to any port 5353  # mDNS
pass out on lo0 all                           # Loopback
```

**Allowlist mode (inverse logic):**
```
# Block everything by default
block return out proto tcp from any to any
block return out proto udp from any to any

# Only allow specific destinations
pass out proto tcp from any to 1.2.3.4
pass out proto udp from any to 1.2.3.4

# Essential services still allowed
pass out proto udp from any to any port 53
# ... etc
```

### 4.4 Block Entry Format

```
Format: [hostname]:[port]/[masklen]

Examples:
  facebook.com           - Block all ports
  smtp.gmail.com:25      - Block only port 25
  192.168.1.0/24         - Block IP range
  *:443                  - Block port 443 everywhere
```

---

## 5. Data Flow Diagrams

### 5.1 Block Activation Flow

```mermaid
sequenceDiagram
    participant User
    participant App as SelfControl.app
    participant XPC as XPC Connection
    participant Daemon as selfcontrold
    participant BM as BlockManager
    participant HF as HostFileBlocker
    participant PF as PacketFilter
    participant System as macOS Kernel

    User->>App: Click "Start Block"
    App->>App: Validate blocklist
    App->>App: Check internet (optional)

    rect rgb(240, 240, 240)
        Note over App: Background Thread
        App->>XPC: Create connection
        XPC->>Daemon: startBlock(blocklist, endDate)
    end

    Daemon->>Daemon: Acquire method lock
    Daemon->>Daemon: Store settings
    Daemon->>BM: installBlockRules()

    par Parallel Operations
        BM->>HF: Add hosts entries
        BM->>PF: Add firewall rules
    end

    BM->>HF: Write /etc/hosts
    HF->>System: Modify /etc/hosts

    BM->>PF: Execute pfctl
    PF->>System: Load PF rules

    Daemon->>Daemon: Start checkup timer
    Daemon-->>App: Success
    App->>User: Show timer window
```

### 5.2 Checkup Timer Flow

```mermaid
flowchart TD
    A[Timer fires every 1 second] --> B{Block expired?}
    B -->|No| C{Rules intact?}
    C -->|Yes| D[Continue monitoring]
    C -->|No| E[Restore from backup]
    E --> F[Reinstall rules]
    F --> D
    B -->|Yes| G[Remove block rules]
    G --> H[Clear hosts section]
    H --> I[Remove PF rules]
    I --> J[Update settings]
    J --> K[Kill daemon]

    style G fill:#4ecdc4,color:#fff
    style K fill:#ff6b6b,color:#fff
```

### 5.3 Settings Synchronization

```mermaid
flowchart LR
    subgraph "App (User Space)"
        A[SCSettings<br/>Read-Only Mode]
    end

    subgraph "Daemon (Root)"
        B[SCSettings<br/>Read-Write Mode]
        C[Sync Timer<br/>30 sec batching]
    end

    subgraph "Filesystem"
        D[/usr/local/etc/.{hash}.plist]
    end

    A -->|Read| D
    B -->|Write| D
    C -->|Debounced| B

    style D fill:#4ecdc4,color:#fff
```

---

## 6. Module Reference

### 6.1 Directory Structure

```
SelfControl/
├── AppController.m/h              # Main app UI controller
├── TimerWindowController.m/h      # Active block timer window
├── DomainListWindowController.m/h # Blocklist editor
├── cli-main.m                     # CLI entry point
│
├── Block Management/              # CORE BLOCKING LOGIC
│   ├── BlockManager.m/h          # Orchestrator
│   ├── HostFileBlocker.m/h       # /etc/hosts
│   ├── HostFileBlockerSet.m/h    # Multiple hosts files
│   ├── PacketFilter.m/h          # PF rules
│   ├── SCBlockEntry.m/h          # Block entry model
│   ├── HostImporter.m/h          # Import from mail apps
│   └── AllowlistScraper.m/h      # Parse allowlists
│
├── Daemon/                        # PRIVILEGED DAEMON
│   ├── DaemonMain.m              # Entry point
│   ├── SCDaemon.m/h              # Lifecycle & XPC listener
│   ├── SCDaemonBlockMethods.m/h  # Block operations
│   ├── SCDaemonXPC.m/h           # XPC handler
│   └── SCDaemonProtocol.h        # XPC interface
│
├── Common/                        # SHARED CODE
│   ├── SCSettings.m/h            # Settings management
│   ├── SCXPCClient.m/h           # App-side XPC
│   ├── SCBlockFileReaderWriter.m/h # .selfcontrol files
│   ├── SCFileWatcher.m/h         # Tamper detection
│   └── Utility/
│       ├── SCBlockUtilities.m/h  # Block state checks
│       ├── SCHelperToolUtilities.m/h # Privileged ops
│       └── SCMiscUtilities.m/h   # General helpers
│
├── SCKillerHelper/                # Kill processes helper
└── SelfControl Killer/            # App killer GUI
```

### 6.2 Key Classes Quick Reference

| Class | Purpose | Touch for... |
|-------|---------|--------------|
| `AppController` | Main UI, block initiation | UI changes, block start flow |
| `BlockManager` | Orchestrates blocking | Adding new block types |
| `HostFileBlocker` | /etc/hosts manipulation | DNS-level blocking |
| `PacketFilter` | PF rule generation | Firewall rules |
| `SCBlockEntry` | Block entry data model | New entry formats |
| `SCDaemonBlockMethods` | Daemon block operations | Block lifecycle |
| `SCSettings` | Centralized settings | New preferences |
| `SCXPCClient` | App→Daemon communication | New XPC methods |

---

## 7. Security Model

### 7.1 Privilege Separation

```mermaid
graph TB
    subgraph "Unprivileged (User)"
        A[SelfControl.app]
        B[Cannot modify /etc/*]
        C[Cannot load PF rules]
    end

    subgraph "Privileged (Root)"
        D[selfcontrold]
        E[Modifies /etc/hosts]
        F[Runs pfctl]
        G[Writes to /usr/local/etc]
    end

    A -->|XPC + Auth| D
    D --> E
    D --> F
    D --> G

    style D fill:#ff6b6b,color:#fff
```

### 7.2 XPC Security

1. **Code Signing Verification:** Daemon validates app's certificate
2. **Bundle ID Check:** Only `org.eyebeam.SelfControl` or CLI accepted
3. **Version Check:** Minimum version 4.0.7 required
4. **Team ID Validation:** Must match `L5YX8CH3F5`

### 7.3 Tampering Detection

```mermaid
flowchart LR
    A[SCFileWatcher] -->|Monitors| B[/etc/hosts]
    B -->|Changed| C{Block active?}
    C -->|Yes| D[checkBlockIntegrity]
    D -->|Tampered| E[Set TamperingDetected]
    E --> F[Change wallpaper]
    D -->|OK| G[Continue]

    style F fill:#ff6b6b,color:#fff
```

---

## 5. App Blocking (NEW)

### 5.1 Overview

App blocking adds a third layer of protection by monitoring and killing blocked applications.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    THREE-LAYER BLOCKING ARCHITECTURE                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Layer 1: DNS Redirect (/etc/hosts) ............ [EXISTING]            │
│   Layer 2: Packet Filter (PF Rules) ............. [EXISTING]            │
│   Layer 3: App Blocker (Process Kill) ........... [NEW]                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Entry Format

```
facebook.com           → Network block (Layer 1 + 2)
app:com.apple.Terminal → App block (Layer 3)
app:com.cursor.Cursor  → App block (Layer 3)
smtp.gmail.com:25      → Port-specific block (Layer 1 + 2)
```

### 5.3 Key Components

| File | Purpose |
|------|---------|
| `Block Management/AppBlocker.h/m` | Process monitor with 500ms timer |
| `Block Management/SCBlockEntry.h/m` | Extended with `appBundleID` property |
| `Block Management/BlockManager.h/m` | Routes app entries to AppBlocker |

### 5.4 How It Works

```mermaid
flowchart TD
    A[Block starts] --> B[BlockManager parses entries]
    B --> C{Entry type?}
    C -->|Network| D[Add to hosts + PF]
    C -->|App| E[Add to AppBlocker]
    E --> F[Start 500ms timer]
    F --> G[findAndKillBlockedApps]
    G --> H{App running?}
    H -->|Yes| I[forceTerminate]
    H -->|No| J[Continue]
    I --> J
    J --> G
```

---

## 6. Debug Features

All debug features are **DEBUG builds only** - compiled out of release builds via `#ifdef DEBUG`.

### 6.1 Disable All Blocking

Debug mode allows disabling ALL blocking during development.

- **Access:** Debug > Disable All Blocking menu
- **Indicator:** Window title shows "[DEBUG - BLOCKING DISABLED]"

**What Gets Bypassed:**

| Blocker | When debug mode ON |
|---------|-------------------|
| PacketFilter.startBlock | Returns early, no PF rules |
| HostFileBlocker.writeNewFileContents | Returns early, no hosts changes |
| AppBlocker.findAndKillBlockedApps | Returns empty array, no kills |

### 6.2 Startup Safety Check

Automatically verifies blocking works correctly after macOS or app version changes.

```mermaid
flowchart LR
    A[App launches] --> B{Version changed?}
    B -->|No| C[Normal startup]
    B -->|Yes| D[Show safety check dialog]
    D --> E{User choice}
    E -->|Skip| C
    E -->|Run Test| F[30-second block test]
    F --> G[Verify blocking]
    G --> H[Wait for expiry]
    H --> I[Verify cleanup]
    I --> J[Show results]
```

**Trigger Conditions:**
- First launch after macOS update
- First launch after SelfControl app update
- User can skip (versions marked as tested)

**What Gets Tested:**

| Test | Verifies |
|------|----------|
| Hosts block | example.com added to /etc/hosts |
| PF block | Packet filter rules loaded |
| App block | Calculator.app gets killed |
| Hosts cleanup | example.com removed after expiry |
| PF cleanup | Packet filter rules removed |
| App cleanup | Calculator.app can run again |

**Key Files:**

| File | Purpose |
|------|---------|
| `Common/SCStartupSafetyCheck.h/m` | Test orchestration |
| `Common/Utility/SCVersionTracker.h/m` | Version change detection |
| `SCSafetyCheckWindowController.h/m` | Test UI window |

**Test Parameters:**
- Duration: 30 seconds
- Network target: example.com
- App target: com.apple.calculator (Calculator)

---

## 7. Extension Points

### 7.1 Adding New Block Types

The current architecture is extensible via:

1. **SCBlockEntry** - Add new properties (like `appBundleID`)
2. **BlockManager** - Route entries to appropriate blockers
3. **New Blocker Class** - Implement blocking logic

### 7.2 Future Possibilities

| Extension | Approach |
|-----------|----------|
| System Extension (ES) | Prevent app launch entirely (no flicker) |
| Network Extension | Per-app network blocking |
| Screen Time integration | Use native macOS APIs |

---

## 8. Quick Reference

### 8.1 Important Paths

| Path | Purpose |
|------|---------|
| `/etc/hosts` | DNS redirect rules |
| `/etc/hosts.bak` | Backup before modification |
| `/etc/pf.conf` | Packet filter main config |
| `/etc/pf.anchors/org.eyebeam` | SelfControl's PF rules |
| `/usr/local/etc/.{SHA1}.plist` | Persistent settings |
| `/Library/LaunchDaemons/org.eyebeam.selfcontrold.plist` | Daemon config |
| `/Library/PrivilegedHelperTools/org.eyebeam.selfcontrold` | Daemon binary |

### 8.2 Key Settings

| Setting | Type | Purpose |
|---------|------|---------|
| `BlockIsRunning` | BOOL | Is block currently active? |
| `BlockEndDate` | NSDate | When does block expire? |
| `ActiveBlocklist` | Array | Currently blocked entries |
| `ActiveBlockAsWhitelist` | BOOL | Allowlist mode? |
| `TamperingDetected` | BOOL | Was tampering found? |
| `EvaluateCommonSubdomains` | BOOL | Auto-block www., mail., etc.? |
| `IncludeLinkedDomains` | BOOL | Block related domains? |
| `AllowLocalNetworks` | BOOL | Allow LAN access? |
| `ClearCaches` | BOOL | Clear browser caches? |
| `DebugBlockingDisabled` | BOOL | Debug override (DEBUG builds only) |

### 8.3 Error Codes

| Code | Meaning |
|------|---------|
| 100 | Blocklist empty (non-allowlist mode) |
| 104 | Block already running |
| 300 | Daemon method lock timeout |
| 301 | Cannot start - block running |
| 302 | Blocklist empty or block expired |

### 8.4 XPC Methods

```objc
// Start a new block
- (void)startBlockWithControllingUID:(uid_t)uid
                           blocklist:(NSArray<NSString*>*)blocklist
                         isAllowlist:(BOOL)isAllowlist
                             endDate:(NSDate*)endDate
                       blockSettings:(NSDictionary*)settings
                               reply:(void(^)(NSError*))reply;

// Add entries to active block
- (void)updateBlocklist:(NSArray<NSString*>*)newEntries
                  reply:(void(^)(NSError*))reply;

// Extend block duration
- (void)updateBlockEndDate:(NSDate*)newEndDate
                     reply:(void(^)(NSError*))reply;

// Get daemon version
- (void)getVersionWithReply:(void(^)(NSString*))reply;
```

---

## Appendix A: Build Targets

| Target | Type | Output |
|--------|------|--------|
| SelfControl | Application | SelfControl.app |
| selfcontrold | Helper Tool | org.eyebeam.selfcontrold |
| selfcontrol-cli | Command Line | selfcontrol-cli |
| SCKillerHelper | Helper Tool | SCKillerHelper |
| SelfControl Killer | Application | SelfControl Killer.app |

---

## Appendix B: Thread Safety

| Lock | Location | Purpose |
|------|----------|---------|
| `refreshUILock_` | AppController | Prevent UI race conditions |
| `modifyBlockLock` | TimerWindowController | Single add/extend sheet |
| `strLock` | HostFileBlocker | Thread-safe hosts manipulation |
| `daemonMethodLock` | SCDaemonBlockMethods | Exclusive block operations |

---

## Appendix C: Notification Names

| Notification | Purpose |
|--------------|---------|
| `org.eyebeam.SelfControl.SCSettingsValueChanged` | Settings changed (distributed) |
| `SCConfigurationChangedNotification` | Internal config change |

---

*This document is auto-generated and should be updated when significant architectural changes are made.*
