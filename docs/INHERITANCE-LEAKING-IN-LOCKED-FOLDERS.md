# Inheritance Leaking in Locked (Restricted) Folders

## Overview

OneDrive Personal "locked" folders (folders that broke inheritance via the move-to-root workaround) are **not fully isolated** from parent permission changes. Certain operations at the parent level will **leak through** into locked subfolders, effectively re-introducing inherited permissions.

This document describes two confirmed leaking behaviors and their implications.

## Related Documentation

- `PHANTOM-INHERITANCE-BUG.md` — Describes the phantom security scope mechanism and the move-to-root workaround
- `PERMISSION-INHERITANCE-DETECTION.md` — How to detect inherited vs. unique permissions via Graph API

## Behavior 1: New Users Added at Parent Leak into Locked Folders

**Documented in:** `PHANTOM-INHERITANCE-BUG.md` (Selective inheritance behavior)

### Summary

When a **new user** is added to a parent folder, that permission **propagates into all locked subfolders** as an inherited permission — even though those subfolders had previously broken inheritance.

### Mechanism

- OLD permissions (present when inheritance was broken): Do NOT propagate
- NEW permissions (added after inheritance was broken): DO propagate
- The phantom security scope actively relays new permissions to children

### Consequence

Every time a new user is added at the top level, **all locked subfolders must be re-secured** using the move-to-root workaround:

1. Move locked subfolder to OneDrive root
2. Remove the leaked inherited user
3. Move folder back to original location

### Example

```
Before:
  Root entity (15 users)
  └── 🔒 Board Reports (6 users, RESTRICTED)

Action: Add newuser@example.com to Root entity

After:
  Root entity (16 users)
  └── 🔒 Board Reports (7 users!) ← newuser leaked in as inherited
```

## Behavior 2: Permission Role Changes at Parent Leak into Locked Folders

**Discovered:** 2026-02-14

### Summary

When an **existing user's role is changed** at the parent level (e.g., write → read), the change **propagates into locked subfolders** — even adding the user to folders they were not previously in.

### Observed Evidence

**Setup:** `tom.jose.sunil@gmail.com` had **write** access at the root entity folder. He was **not present** in either locked subfolder:
- 🔒 Board Reports and Meetings — 6 users, sunil NOT listed
- 🔒 Contracts, Payroll, Super, and PAYG — 5 users, sunil NOT listed

**Action:** Changed sunil from **write → read** at the root entity level.

**Result:**

| Folder | sunil before | sunil after | Type |
|--------|:---:|:---:|:---:|
| Root entity | write | **read** | changed |
| 👔 Corporate Management (unlocked) | write | **read** | inherited change |
| 🔒 Board Reports (locked) | not present | **read** (appeared!) | leaked |
| 🔒 Contracts/Payroll (locked) | not present | **read** (appeared!) | leaked |
| 💰 Financial Management (unlocked) | write | **read** | inherited change |

### Analysis

The write → read change at the parent level is internally processed as:
1. **Remove** the old write permission
2. **Add** a new read permission

Because the "add new permission" operation propagates through the phantom security scope (Behavior 1), the new read permission leaked into locked folders. The user appeared in folders where they had **never** previously been listed.

### Key Insight

A role change (write ↔ read) at the parent level is **not atomic** from the permission system's perspective. It creates a "new" permission entry that triggers the phantom scope propagation, even into locked folders that had specifically excluded that user.

## Implications for ACL Management

### Every locked folder is fragile

The "locked" state is not a firewall. It is a **snapshot** of which users were excluded at the time inheritance was broken. Any subsequent parent-level change that creates new permission entries will leak through.

### Operations that cause leaking

| Parent-level operation | Leaks into locked folders? |
|------------------------|:---:|
| Add new user | Yes |
| Change user role (write → read) | Yes |
| Change user role (read → write) | Yes (new permission created) |
| Remove user | No (removes from child too) |
| No change to existing users | No |

### Remediation workflow

When a parent-level change causes leaking, each affected locked folder must be individually re-secured:

```bash
# For each locked folder that was contaminated:

# 1. Move to root (severs phantom inheritance)
rclone moveto "OneDrive:Parent/🔒 Locked Folder" "OneDrive:🔒 Locked Folder"

# 2. Remove leaked user(s)
tclsh acl-manager.tcl --remove-user leaked@example.com "🔒 Locked Folder"

# 3. Move back
rclone moveto "OneDrive:🔒 Locked Folder" "OneDrive:Parent/🔒 Locked Folder"

# 4. Verify
tclsh acl-manager.tcl "Parent/🔒 Locked Folder"
```

### Prevention

There is no way to prevent leaking in OneDrive Personal. The only mitigation strategies are:

1. **Audit after every parent change** — Run `acl-manager.tcl -r` on parent folders after any permission modification to detect leaks
2. **Minimize parent-level changes** — Add users at the most specific folder level possible, not at the top
3. **Accept and remediate** — Treat locked folders as requiring periodic maintenance after any parent ACL change

## Microsoft Graph API Context

OneDrive Personal does not support:
- `HasUniqueRoleAssignments` property (SharePoint/OneDrive Business only)
- Breaking inheritance via API (no equivalent of SharePoint's `BreakRoleInheritance`)
- Deleting inherited permissions (API returns error)

The move-to-root workaround is the only known method to convert inherited permissions to unique (deletable) permissions.

## See Also

- `PHANTOM-INHERITANCE-BUG.md` — The underlying phantom security scope mechanism
- `PERMISSION-INHERITANCE-DETECTION.md` — Detecting inheritance status via Graph API
