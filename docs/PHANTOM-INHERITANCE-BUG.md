# OneDrive Phantom Inheritance Permission Bug

## Overview

This document describes a critical bug in OneDrive/SharePoint permission inheritance where folders can enter a "zombie inheritance state" that prevents removal of inherited permissions through the Microsoft Graph API.

## The Problem

### Symptom
When attempting to remove a user's permission from a child folder using `--remove-user`, the operation fails with "does not have explicit access" even though the user clearly has access when viewing the folder's ACL.

### Example
```bash
./acl-manager.tcl --remove-user john_2217@icloud.com \
  "🇦🇺 Colourful.land Pty Ltd/👷 Human Resources/🔒 Contracts, Payroll, Super, and PAYG"
```

Result: Tool reports "does not have explicit access" but user still has access to the folder.

## Root Cause: Phantom Inheritance Scope

### What We Discovered

1. **Child folders can inherit from non-existent scopes**
   - Permissions show `inheritedFrom` field pointing to ID like `5D1B2B3BE100F93B!se100f93b2b3b201b805dcf4001000000`
   - This ID returns HTTP 404 when queried directly
   - The ID does NOT match the actual parent folder ID
   - The "se" prefix likely indicates "security scope" that has been deleted or orphaned

2. **Selective inheritance behavior**
   - NEW permissions added to parent: **Propagate to child** (marked as inherited)
   - OLD permissions from before scope break: **Do NOT propagate**
   - Removing permission from parent: **Also removes from child**
   - Re-adding permission to parent: **Re-appears on child as inherited**

3. **Microsoft Graph API limitation**
   - API prohibits deletion of inherited permissions (acl-manager.tcl:2668)
   - Documentation states: "Only sharing permissions that are not inherited can be deleted. The inheritedFrom property must be null."
   - Phantom inherited permissions cannot be removed through normal API calls

## Experiments & Verification

### Experiment 1: Initial State Analysis
**Hypothesis**: User has explicit permission on child folder

**Method**:
1. Check user permission on parent folder
2. Check user permission on child folder
3. Compare permission IDs and inheritance status

**Results**:
- Parent folder: John has explicit (non-inherited) permission
- Child folder: John has "inherited" permission from phantom scope `5D1B2B3BE100F93B!se100f93b2b3b201b805dcf4001000000`
- Phantom scope ID returns 404 Not Found
- Child folder is NOT inheriting from direct parent (different IDs)

**Conclusion**: Contradicts assumption that child inherits from parent. Child inherits from deleted/phantom scope.

---

### Experiment 2: Permission Removal and Re-addition
**Hypothesis**: Removing and re-adding permission might reset inheritance

**Method**:
1. Remove user from parent folder
2. Verify user removed from child folder
3. Re-add user to parent folder
4. Check if user re-appears on child folder

**Results**:
1. Removed John from parent → John disappeared from child
2. Re-added John to parent → John re-appeared on child as "inherited"
3. Permission still shows same phantom `inheritedFrom` scope ID

**Conclusion**: Contradicts theory that inheritance is static. The phantom scope actively propagates NEW permissions added to parent, proving it's not a snapshot but an active (broken) inheritance link.

---

### Experiment 3: Comparing with Non-Inheriting User
**Hypothesis**: Some users don't inherit due to when they were added

**Initial Theory**: Barbara (old permission) doesn't inherit because she was added before scope break, John (new) inherits because added after.

**Reality**: OPPOSITE is true
- John was added most recently (newest permission)
- Barbara's permission has existed for over a year
- John inherits, Barbara does not

**Method**:
1. Check both users on parent folder
2. Check both users on child folder
3. Compare when permissions were added (newest vs oldest)

**Results**:
- Parent: Both John and Barbara have explicit permissions
- Child: John appears as "inherited", Barbara does NOT appear at all
- Timeline contradicts initial theory

**Conclusion**: The inheritance behavior is NOT based on when permissions were added. The phantom scope somehow selectively propagates certain users but not others, suggesting the scope contains a frozen subset of users from when it was created.

---

### Experiment 4: Move-to-Root Workaround
**Hypothesis**: Moving folder to root severs phantom inheritance link

**Method**:
1. Move problematic child folder to OneDrive root
2. Check if inherited permissions become unique
3. Remove user's unique permission
4. Move folder back to original location
5. Verify user does not re-appear

**Results**:
1. After move to root: John's permission changed from "inherited" to "unique"
2. Successfully removed John's unique permission
3. After move back: John did NOT re-appear on child folder
4. Parent still has John's permission
5. Other inherited users remain on child folder

**Conclusion**: ✅ WORKAROUND CONFIRMED - Moving to root breaks phantom inheritance and converts inherited permissions to unique permissions that can be deleted.

## The Workaround

### Procedure

1. **Move folder to root**
   - Use OneDrive web UI or Microsoft Graph API
   - Move the problematic folder to OneDrive root level

2. **Remove user permission**
   - Permission is now "unique" (not inherited)
   - Can be removed using `--remove-user`:
   ```bash
   ./acl-manager.tcl --remove-user user@example.com "FolderName"
   ```

3. **Move folder back**
   - Return folder to original location
   - User will NOT re-appear (inheritance link is broken)

### Why This Works

Moving the folder to root **severs the phantom inheritance scope link**:
- Inherited permissions become unique/explicit permissions
- Once unique, they can be deleted via Graph API
- When moved back, folder maintains its new permission set
- No longer connected to phantom scope

### Alternative: Manual via Web UI

The same effect can be achieved by:
1. Navigate to folder in OneDrive web interface
2. Drag folder to root level
3. Right-click folder → Manage Access → Remove user
4. Drag folder back to original location

## Technical Details

### Permission ID Format Analysis

**Normal Folder ID**: `5D1B2B3BE100F93B!82127`
- Format: `{DriveId}!{ItemId}`

**Phantom Scope ID**: `5D1B2B3BE100F93B!se100f93b2b3b201b805dcf4001000000`
- Format: `{DriveId}!se{UniqueId}`
- "se" prefix likely means "security scope"
- Returns 404 when queried
- Still referenced in `inheritedFrom` field of child permissions

### Graph API Response Structure

Inherited permission with phantom scope:
```json
{
  "id": "aTowIy5mfG1lbWJlcnNoaXB8dXNlckBleGFtcGxlLmNvbQ",
  "roles": ["write"],
  "inheritedFrom": {
    "id": "5D1B2B3BE100F93B!se100f93b2b3b201b805dcf4001000000",
    "path": "/drives/5D1B2B3BE100F93B/root:/Parent Folder",
    "driveId": "5D1B2B3BE100F93B"
  }
}
```

After moving to root (becomes unique):
```json
{
  "id": "aTowIy5mfG1lbWJlcnNoaXB8dXNlckBleGFtcGxlLmNvbQ",
  "roles": ["write"]
}
```
Note: `inheritedFrom` field is absent, making permission deletable.

## Tool Behavior

### Why `has_explicit_user_permission` Skips These

File: `acl-manager.tcl:2660-2681`

```tcl
proc has_explicit_user_permission {permissions target_user_lower} {
    foreach perm $permissions {
        if {[is_owner_permission $perm]} {
            continue
        }

        if {[is_inherited_permission $perm]} {
            continue  # Line 2668: Skips inherited permissions
        }

        # ... check user email ...
    }
}
```

The tool **correctly implements** Microsoft's Graph API specification which states inherited permissions cannot be deleted. The bug is in OneDrive/SharePoint creating phantom inherited permissions that cannot be removed through normal means.

## When This Occurs

### Likely Causes

1. **Permission inheritance was broken** on the folder at some point
2. **Folder was moved** between locations with different permission scopes
3. **Parent folder permissions changed** after child already had unique permissions
4. **SharePoint sync issues** between OneDrive and SharePoint backend
5. **Security scope was deleted** but child folders still reference it

### How to Detect

```bash
# Check if user has access
./acl-manager.tcl --only-user user@example.com "Path/To/Folder"

# Try to remove (will fail if phantom inheritance)
./acl-manager.tcl --remove-user user@example.com "Path/To/Folder"
```

If you see "does not have explicit access" but user shows up in folder ACL, you have phantom inheritance.

## References

### Microsoft Documentation
- [Remove access to an item - Microsoft Graph API](https://learn.microsoft.com/en-us/graph/api/permission-delete?view=graph-rest-1.0)
- [SharePoint Permission Scopes](https://learn.microsoft.com/en-us/sharepoint/manage-permission-scope)
- [SharePoint ScopeID Documentation](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-sitedats/1dfa5648-4093-4147-8465-fbe8671c83c4)

### Community Discussions
- [Microsoft Graph API to Stop Inheriting Permissions in OneDrive items](https://stackoverflow.com/questions/51411531/microsoft-graph-api-to-stop-inheriting-permissions-in-one-drive-items)
- [Clarifying The Security Scope Limits In SharePoint Lists](https://reality-tech.com/blog/clarifying-the-security-scope-limits-in-sharepoint-lists/)
- [Permission scopes in SharePoint Web Services](https://thomask.sdf.org/blog/2017/12/16/permission-scopes-sharepoint-web-services.html)

## Summary

This is an **undocumented OneDrive/SharePoint permission sync bug** where:
- Child folders can inherit from deleted/phantom security scopes
- Permissions appear as "inherited" from non-existent sources
- Graph API blocks deletion of these phantom inherited permissions
- Moving folder to root is the only known workaround

The move-to-root workaround was discovered through experimentation and successfully tested on 2024-11-22.
