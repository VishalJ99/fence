# Fence Blocking Mechanism Deep Dive

> **Purpose:** Technical documentation of how blocking works and how to extend it for app blocking

---

## Current Blocking Architecture

### Schedule Activation Authority (PER-383)

The blocking mechanisms below are unchanged: `BlockManager` still owns the
physical hosts, PF, and AppBlocker apply/teardown operations. What changed is
who decides *when* a committed schedule should call them.

For new V2 commitments, `SCDaemonScheduler` in the root daemon selects the
desired absolute segment from root-owned `ApprovedSchedules` and calls
`SCDaemonBlockMethods`. It evaluates at the next exact boundary and at
startup/wake/clock/timezone/mutation/completion triggers, with a 60-second
backstop. New commitments do not create per-segment LaunchAgents or run the
CLI at the boundary.

Active provenance distinguishes manual, safety-test, legacy-schedule, and V2
scheduler blocks. Manual/test enforcement is never replaced automatically.
Likewise, if a V2 mutation selects a different policy while another
schedule-owned block is active, the scheduler defers: this cutover does not
remove current rules and then add replacements. A verified match includes
schedule/owner provenance, mode and content, and for V2 also commitment,
generation, and policy revision.

The existing one-minute inter-segment compatibility gap remains. Removing it
requires a separate physical replacement primitive that stages the new
PF/hosts/AppBlocker policy before dropping obsolete rules.

Existing V1 LaunchAgents, CLI selectors, and approvals remain only as a
bounded current/next-week rollback/drain path. They are not removed by V2
commit: an unexpired V1 record rejects an overlapping V2 absolute-week
envelope. The inverse is also guarded: legacy registration rejects an
unexpired overlapping V2 envelope. V2 envelopes are immutable, include
zero-segment commitments, and make exact same-batch identity/content retries
idempotent. Release builds reject bulk approved-schedule clearing; DEBUG tests
clear the envelope and record maps together. See
[SCHEDULE_JOB_LIFECYCLE.md](SCHEDULE_JOB_LIFECYCLE.md).

### The Two Walls

SelfControl blocks network access using **two independent mechanisms**. This dual-layer approach ensures that bypassing one layer still leaves the other active.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         BLOCKING ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Wall 1: DNS Redirect (/etc/hosts)                                     │
│   ┌───────────────────────────────────────────────────────────────┐     │
│   │  facebook.com  →  0.0.0.0 (goes nowhere)                      │     │
│   │  twitter.com   →  ::      (IPv6 nowhere)                      │     │
│   │                                                                │     │
│   │  How: System checks /etc/hosts BEFORE DNS servers            │     │
│   │  Bypass: Direct IP access (that's why we need Wall 2)        │     │
│   └───────────────────────────────────────────────────────────────┘     │
│                                                                          │
│   Wall 2: Packet Filter (macOS Firewall)                                │
│   ┌───────────────────────────────────────────────────────────────┐     │
│   │  block return out proto tcp from any to 157.240.1.35         │     │
│   │  block return out proto udp from any to 104.244.42.1         │     │
│   │                                                                │     │
│   │  How: Kernel intercepts packets before they leave            │     │
│   │  Catches: Direct IP access that bypasses DNS                 │     │
│   └───────────────────────────────────────────────────────────────┘     │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Both?

| Scenario | Wall 1 (hosts) | Wall 2 (PF) |
|----------|---------------|-------------|
| User types facebook.com | ✅ Blocks | (never reached) |
| User uses IP directly | ❌ Bypassed | ✅ Blocks |
| User modifies /etc/hosts | ❌ Removed | ✅ Still blocks |
| User flushes PF rules | ✅ Still blocks | ❌ Removed |

---

## Detailed Blocking Flow

### 1. User Initiates Block

```
User clicks "Start Block"
         │
         ▼
┌─────────────────────────┐
│   AppController.m:234   │
│   addBlock:             │
│   - Validate blocklist  │
│   - Check duration      │
│   - Start bg thread     │
└─────────────────────────┘
         │
         ▼ (background thread)
┌─────────────────────────┐
│   AppController.m:312   │
│   installBlock:         │
│   - Get authorization   │
│   - Create XPC client   │
│   - Call daemon         │
└─────────────────────────┘
```

### 2. Daemon Receives Request

```
XPC Call arrives at daemon
         │
         ▼
┌────────────────────────────────┐
│  SCDaemonBlockMethods.m:89     │
│  startBlock:                   │
│  - Acquire method lock         │
│  - Validate parameters         │
│  - Store in SCSettings         │
└────────────────────────────────┘
         │
         ▼
┌────────────────────────────────┐
│  SCHelperToolUtilities.m:45    │
│  installBlockRulesFromSettings │
│  - Create BlockManager         │
│  - Call prepareToAddBlock      │
│  - Add each entry              │
│  - Finalize block              │
└────────────────────────────────┘
```

### 3. BlockManager Orchestrates

```
BlockManager.m
         │
         ├──► prepareToAddBlock() ──► Clear old entries from /etc/hosts
         │
         ├──► addBlockEntriesFromStrings() ──► For each entry:
         │         │
         │         ├── Parse entry (hostname:port/mask)
         │         ├── If IP: add PF rule
         │         └── If domain:
         │              ├── Resolve to IP(s) via DNS
         │              ├── Add PF rules for each IP
         │              ├── Add hosts file entries
         │              └── Handle subdomains if enabled
         │
         └──► finalizeBlock() ──► Write files, activate PF
```

### 4. Actual System Modifications

**HostFileBlocker.m - DNS Redirect:**
```objc
// Line ~89
- (BOOL)addRuleBlockingDomain:(NSString*)domain {
    // Add IPv4 redirect
    [hostFileContents appendFormat:@"0.0.0.0\t%@\n", domain];
    // Add IPv6 redirect
    [hostFileContents appendFormat:@"::\t%@\n", domain];
}
```

**PacketFilter.m - Firewall Rules:**
```objc
// Line ~67
- (void)addRuleWithIP:(NSString*)ip port:(int)port maskLen:(int)mask {
    if (port == 0) {
        // Block all ports
        [rules appendFormat:@"block return out proto tcp from any to %@\n", ip];
        [rules appendFormat:@"block return out proto udp from any to %@\n", ip];
    } else {
        // Block specific port
        [rules appendFormat:@"block return out proto tcp from any to %@ port %d\n", ip, port];
    }
}
```

### 5. Enforcement Activation

```objc
// PacketFilter.m:~120
- (void)startBlock {
    // Write rules to anchor file
    [rules writeToFile:@"/etc/pf.anchors/org.eyebeam" atomically:YES];

    // Reload packet filter
    NSTask *pfctl = [[NSTask alloc] init];
    pfctl.launchPath = @"/sbin/pfctl";
    pfctl.arguments = @[@"-f", @"/etc/pf.conf"];
    [pfctl launch];
}
```

---

## The Checkup Timer

**Purpose:** Ensure block persists even if user tries to tamper

```
Every 1 second (SCDaemonBlockMethods.m:~200):
┌──────────────────────────────────────────────────────┐
│                    checkupBlock()                     │
├──────────────────────────────────────────────────────┤
│                                                       │
│  1. Check if BlockEndDate has passed                 │
│     └── If yes: Remove block, notify root scheduler  │
│                                                       │
│  2. Verify /etc/hosts contains SelfControl section   │
│     └── If missing: Restore from .bak                │
│                                                       │
│  3. Verify PF rules are loaded                       │
│     └── If missing: Reload pfctl                     │
│                                                       │
│  4. Check for tampering                              │
│     └── If detected: Set punishment flag             │
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

## App Blocking Implementation

### Overview

SelfControl now supports blocking **applications** in addition to network destinations. Blocked apps are immediately terminated when launched.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    EXTENDED BLOCKING ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Wall 1: DNS Redirect (/etc/hosts) ............ [EXISTING]             │
│                                                                          │
│   Wall 2: Packet Filter (PF Rules) ............. [EXISTING]             │
│                                                                          │
│   Wall 3: App Blocker (Process Control) ........ [IMPLEMENTED]          │
│   ┌───────────────────────────────────────────────────────────────┐     │
│   │  Process Monitor + Kill (AppBlocker singleton)                │     │
│   │  - Polls running processes every 500ms via libproc            │     │
│   │  - Extracts bundle ID from .app/Contents/Info.plist           │     │
│   │  - Kills matching processes with SIGTERM/SIGKILL              │     │
│   │  - Singleton pattern ensures persistence across method calls  │     │
│   └───────────────────────────────────────────────────────────────┘     │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Singleton `[AppBlocker sharedBlocker]` | BlockManager is local var, gets deallocated after `finalizeBlock` |
| libproc APIs (`proc_listpids`, `proc_pidpath`) | Daemon runs as root without GUI session, can't use NSWorkspace |
| Bundle ID from `.app/Contents/Info.plist` | Reliable way to get CFBundleIdentifier from executable path |

### Block Entry Format (Extended)

```
Current format:
  hostname[:port][/masklen]

Extended format:
  hostname[:port][/masklen]    - Network block (existing)
  app:com.bundle.identifier   - App block (new)

Examples:
  facebook.com               - Block facebook.com website
  app:com.apple.Terminal     - Block Terminal.app
  app:com.cursor.Cursor      - Block Cursor IDE
  app:org.antigravity.app    - Block Antigravity
  smtp.gmail.com:25          - Block Gmail SMTP
```

---

## Alternative: Endpoint Security (Option B)

For completeness, here's what Option B would require:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ENDPOINT SECURITY APPROACH                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Requires:                                                               │
│  ✗ System Extension entitlement (com.apple.developer.endpoint-security) │
│  ✗ Notarization with Apple                                              │
│  ✗ User must approve extension in System Preferences                    │
│  ✗ Separate extension bundle embedded in app                            │
│                                                                          │
│  How it works:                                                           │
│  1. Extension registers for ES_EVENT_TYPE_AUTH_EXEC                     │
│  2. When any process tries to launch, extension is called               │
│  3. Extension checks bundle ID against blocklist                        │
│  4. Returns ES_AUTH_RESULT_DENY to prevent launch                       │
│                                                                          │
│  Code sketch:                                                            │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │  es_new_client(&client, ^(es_client_t* c, es_message_t* msg) { │     │
│  │      if (msg->event_type == ES_EVENT_TYPE_AUTH_EXEC) {         │     │
│  │          NSString* path = msg->event.exec.target.path;         │     │
│  │          if ([blockedPaths containsObject:path]) {             │     │
│  │              es_respond_auth_result(c, msg,                    │     │
│  │                  ES_AUTH_RESULT_DENY, false);                  │     │
│  │          } else {                                              │     │
│  │              es_respond_auth_result(c, msg,                    │     │
│  │                  ES_AUTH_RESULT_ALLOW, true);                  │     │
│  │          }                                                     │     │
│  │      }                                                         │     │
│  │  });                                                           │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                          │
│  Recommendation: Start with Option A. Migrate to B if users demand.    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Testing App Blocking

### Manual Test Cases

```bash
# 1. Add Terminal to blocklist
#    Entry: app:com.apple.Terminal

# 2. Start block

# 3. Try to open Terminal
open -a Terminal

# Expected: Terminal opens briefly, then closes
# Log should show: "SelfControl: Blocked app com.apple.Terminal (PID xxx)"

# 4. Check that other apps still work
open -a Safari

# Expected: Safari opens normally
```

### Automated Test

```objc
- (void)testAppBlocker {
    AppBlocker* blocker = [[AppBlocker alloc] init];
    [blocker addBlockedApp:@"com.apple.TextEdit"];

    // Launch TextEdit
    [[NSWorkspace sharedWorkspace]
        launchApplication:@"TextEdit"];

    // Wait for launch
    [NSThread sleepForTimeInterval:0.5];

    // Should find and kill it
    NSArray* killed = [blocker findAndKillBlockedApps];

    XCTAssertEqual(killed.count, 1);
    XCTAssertEqualObjects(
        ((NSRunningApplication*)killed[0]).bundleIdentifier,
        @"com.apple.TextEdit"
    );
}
```

---

## App Blocking: Quick Reference

| Task | File | Method |
|------|------|--------|
| Get singleton | `AppBlocker.m` | `+sharedBlocker` |
| Add blocked app | `AppBlocker.m` | `-addBlockedApp:` |
| Start polling | `AppBlocker.m` | `-startMonitoring` |
| Kill blocked apps | `AppBlocker.m` | `-findAndKillBlockedApps` |
| Parse app entry | `SCBlockEntry.m` | `+entryFromString:` |
| Check if app entry | `SCBlockEntry.m` | `-isAppEntry` |
| Route to blocker | `BlockManager.m` | `-addBlockEntry:` |

---

## FAQ

**Q: Why not use launchd to prevent app launch?**
A: launchd can't dynamically block apps based on user-defined rules. It's designed for system services.

**Q: Will this slow down the system?**
A: The 500ms polling is lightweight. `runningApplications` is cached by the system.

**Q: What if the user is in the middle of work when app is killed?**
A: Show a notification before the block starts: "These apps will be blocked: Terminal, Cursor..."

**Q: Can users work around this by renaming apps?**
A: Bundle IDs are embedded in the app. Renaming doesn't change the ID. They'd have to modify the app bundle, which breaks code signing.

---

## Future macOS Risks & Watchlist

> **Purpose:** Track macOS changes that could break the blocking mechanism. Updated based on historical analysis of SelfControl's evolution.

### Historical Context

SelfControl has only been **forced** to change its core blocking mechanism **once** in 15+ years:

| Year | Change | Reason |
|------|--------|--------|
| 2014 | ipfw → pf | Apple removed ipfw entirely in macOS 10.10 Yosemite |

The "two walls" architecture (firewall + hosts file) has been stable since 2009.

---

### Risk Assessment by Component

#### Wall 1: /etc/hosts — MEDIUM-HIGH RISK

| Threat | Likelihood | Impact | Mitigation |
|--------|------------|--------|------------|
| **DNS-over-HTTPS (DoH) system-wide** | HIGH | Bypasses hosts file entirely | Would need Network Extension |
| **DNS-over-TLS (DoT) default** | MEDIUM | Same as DoH | Same as above |
| **SIP protection of /etc/hosts** | LOW | Can't write to hosts file | Would need different approach |
| **MDM-only DNS settings** | LOW | Consumer apps can't modify DNS | Would break for non-enterprise |

**What to watch:**
- Safari/system DoH settings in System Preferences
- WWDC sessions mentioning "encrypted DNS" or "private DNS"
- Changes to `/etc/hosts` permissions in macOS betas

**Search terms:** `"macOS encrypted DNS" system-wide`, `"Apple DoH" bypass hosts file`

---

#### Wall 2: pf (Packet Filter) — MEDIUM RISK

| Threat | Likelihood | Impact | Mitigation |
|--------|------------|--------|------------|
| **pf deprecated for userspace** | MEDIUM | Would need rewrite | Migrate to Network Extension |
| **Write access to /etc/pf.conf restricted** | MEDIUM | Can't add anchor rules | Need System Extension |
| **pfctl requires additional entitlements** | LOW-MEDIUM | App signing changes | Update entitlements |
| **Network Extension becomes required** | MEDIUM | Major architecture change | NEFilterDataProvider |

**What to watch:**
- Console warnings about pf deprecation
- New entitlements required for `/sbin/pfctl`
- Apple documentation pushing Network Extensions over pf

**Search terms:** `"NEFilterDataProvider" tutorial`, `"macOS Network Extension" content filter`, `"pf" deprecated macOS`

---

#### Wall 3: App Blocking (libproc) — LOW-MEDIUM RISK

| Threat | Likelihood | Impact | Mitigation |
|--------|------------|--------|------------|
| **libproc APIs restricted** | LOW | Can't enumerate processes | Use Endpoint Security |
| **SIGKILL restricted for apps** | LOW | Can't terminate apps | Need ES_EVENT_TYPE_AUTH_EXEC |
| **Endpoint Security required** | MEDIUM | Need System Extension | Already documented as Option B |

**What to watch:**
- Entitlement requirements for `proc_listpids`
- TCC prompts for process enumeration
- Endpoint Security becoming the only blessed path

**Search terms:** `"Endpoint Security" macOS app blocking`, `"proc_listpids" entitlement macOS`

---

#### Daemon Architecture (XPC + SMJobBless) — MEDIUM RISK ⚠️

**Status:** `SMJobBless` is **already deprecated** as of macOS 13.0 (Ventura, 2022). Still works, but will eventually be removed.

| Threat | Likelihood | Impact | Mitigation |
|--------|------------|--------|------------|
| **SMJobBless removed entirely** | MEDIUM | Daemon can't install | Use workarounds below |
| **SMAppService doesn't survive app deletion** | HIGH (by design) | Block bypassed by trashing app | Self-extract or .pkg |
| **XPC connection restrictions** | LOW | Auth changes | Follow Apple's XPC guidelines |

**The SMAppService Problem:**

Apple's replacement (`SMAppService`) keeps the helper **inside the app bundle**. Delete the app → helper gone → block bypassed. This breaks SelfControl's security model.

```
SMJobBless (current):   App deleted → Daemon SURVIVES ✅
SMAppService (new):     App deleted → Daemon GONE ❌
```

**Workarounds when SMJobBless is removed:**

| Approach | How It Works | Effort |
|----------|--------------|--------|
| **.pkg installer** | postinstall script copies daemon to /Library/PrivilegedHelperTools/ | Low |
| **Self-extract hack** | Daemon copies itself out of app bundle on first block start | Medium |
| **Bootstrap helper** | Minimal SMAppService helper installs persistent daemon elsewhere | High |

**Recommended:** Switch to **.pkg installer** distribution. Many security tools do this (Little Snitch, etc.). Clean and Apple-approved.

**What to watch:**
- SMJobBless stops working (not just deprecated)
- Xcode refuses to build with SMJobBless
- Console errors about SMJobBless

**Search terms:** `"SMAppService" daemon persistent`, `"SMJobBless" removed macOS`, `pkg postinstall LaunchDaemon`

---

### Recommended Monitoring

**Check before each major macOS release:**

1. [ ] Test on beta — do blocks still work?
2. [ ] Check Console.app for deprecation warnings
3. [ ] Review Xcode build warnings
4. [ ] Search Apple Developer Forums for "pf", "hosts", "firewall"
5. [ ] Review WWDC sessions tagged "Security" or "Networking"

**Red flags that require immediate attention:**

- `/etc/hosts` no longer affects system DNS resolution
- `pfctl` requires new entitlements or TCC prompt
- System Preferences gains "Content Filter" that overrides pf
- Apple announces Network Extension requirement deadline
- **SMJobBless stops compiling or throws runtime errors**

---

### Escape Hatches (If Forced to Migrate)

#### If /etc/hosts stops working:
→ Implement `NEDNSProxyProvider` to intercept DNS at the system level

#### If pf stops working:
→ Implement `NEFilterDataProvider` for content filtering
→ Requires System Extension (user approval in System Preferences)

#### If both stop working:
→ Full migration to Network Extension framework
→ This is likely Apple's intended long-term direction

#### If SMJobBless stops working:
→ Switch to **.pkg installer** distribution (recommended)
→ postinstall script installs daemon to `/Library/PrivilegedHelperTools/`
→ Daemon persists independently of app bundle
→ Alternative: Self-extracting daemon that copies itself out on first block

**Reference implementations:**
- Little Snitch, Lulu — Network Extension for filtering
- Homebrew, MacPorts — .pkg with persistent LaunchDaemons

---

### Version History

| Date | Update |
|------|--------|
| 2025-01 | Initial risk assessment based on 15-year codebase analysis |
| 2025-01 | Updated SMJobBless risk to MEDIUM — already deprecated in macOS 13. Added workarounds (.pkg installer, self-extract) |
| 2026-07 | PER-383 moved V2 schedule timing into `selfcontrold`; physical blocking layers and the one-minute compatibility gap remain unchanged |
