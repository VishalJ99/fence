# Fence Domain Dictionary

> **Purpose:** Canonical source of truth for domain-specific terminology in the scheduling system.
> **Usage:** Agents must reference this dictionary before implementing features involving these terms.

---

## Index

| Term | Brief Definition | Details |
|------|------------------|---------|
| **Editor** | UI sheet for defining allowed windows per bundle/day | [→ Full Entry](dictionary/editor.md) |
| **Allowed Window** | User-defined time range when bundle is NOT blocked | [→ Full Entry](dictionary/allowed-window.md) |
| **Block Window** | Computed inverse of allowed windows - when blocking IS active | [→ Full Entry](dictionary/block-window.md) |
| **Segment** | Time slice with consistent set of active bundles across all schedules | [→ Full Entry](dictionary/segment.md) |
| **Merged Blocklist** | Combined entries from all active bundles in a segment | [→ Full Entry](dictionary/merged-blocklist.md) |
| **Committed State** | Schedule locked after user confirms; cannot be modified | [→ Full Entry](dictionary/committed-state.md) |
| **Pre-Authorized Schedule** | Segment registered with daemon for password-free execution | [→ Full Entry](dictionary/pre-authorized-schedule.md) |
| **Root-Owned Schedule** | Immutable root absolute-week envelope plus zero or more V2 segments, reconciled by `selfcontrold` without a user LaunchAgent | [→ Full Entry](dictionary/root-owned-schedule.md) |
| **Bundle** | Named group of websites/apps with a color for identification | [→ Full Entry](dictionary/bundle.md) |
| **Entry** | Single blocked item (domain or app bundle ID) | [→ Full Entry](dictionary/entry.md) |
| **Week Offset** | Index for week navigation (0=current, 1=next) | [→ Full Entry](dictionary/week-offset.md) |
| **Emergency Unlock** | Escape hatch to break out of committed state using credits | [→ Full Entry](dictionary/emergency-unlock.md) |
| **Emergency Credits** | Limited currency (5 lifetime) for emergency unlocks | [→ Full Entry](dictionary/emergency-credits.md) |
| **Status Pill** | Colored badge showing bundle's blocking state and time till change | [→ Full Entry](dictionary/status-pill.md) |
| **Menu Bar** | macOS status item UI showing bundle status and quick actions | [→ Full Entry](dictionary/menu-bar.md) |
| **Safety Test** | DEBUG-only automated test verifying blocking/unblocking works after version changes | [→ Full Entry](dictionary/safety-test.md) |

---

## Data Flow Overview

```
USER INPUT                    COMPUTATION                   EXECUTION
─────────────────────────────────────────────────────────────────────────

  ┌─────────┐
  │ Editor  │ ◄─── User clicks day cell in week grid
  └────┬────┘
       │
       ▼
┌──────────────┐
│Allowed Window│ ◄─── SCTimeRange: "9:00-17:00" = can access during these hours
└──────┬───────┘
       │
       │ INVERSION (computed by SCScheduleLaunchdBridge)
       ▼
┌─────────────┐
│ Block Window│ ◄─── SCBlockWindow: inverse times when blocking IS active
└──────┬──────┘
       │
       │ SEGMENTATION (calculateBlockSegmentsForBundles:)
       ▼
┌─────────┐
│ Segment │ ◄─── SCBlockSegment: time slice + list of active bundles
└────┬────┘
     │
     │ MERGING (writeMergedBlocklistForBundles:)
     ▼
┌────────────────┐
│Merged Blocklist│ ◄─── Combined entries from all active bundles
└───────┬────────┘
        │
        │ COMMIT (immutable owner/absolute-week batch)
        ▼
┌─────────────────────┐
│ Root-Owned Schedule │ ◄─── Stored and reconciled by selfcontrold
└─────────────────────┘
```

---

## Quick Reference: What Users Define vs What System Computes

| User Defines | System Computes |
|--------------|-----------------|
| Bundles (groups of sites/apps) | Block Windows (inverse of allowed) |
| Allowed Windows (when NOT blocked) | Segments (time slices across bundles) |
| Commitment (locks schedule) | Merged Blocklists (combined entries) |
| | Root-Owned Schedules (immutable envelope + atomic daemon registration) |

---

*Last updated: July 2026 (PER-383)*
