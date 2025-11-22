# Permission Inheritance Detection in OneDrive

## Overview

This document explains how to detect whether a folder has broken inheritance and how to determine if individual permissions are inherited or unique, using the Microsoft Graph API.

## Per-Permission Inheritance Status

### API Response

The Microsoft Graph API provides inheritance information **for each individual permission entry** via the `/permissions` endpoint.

**Endpoint:**
```
GET /me/drive/items/{item-id}/permissions
```

### Response Structure

Each permission object may contain an `inheritedFrom` field:

**Inherited Permission:**
```json
{
  "id": "permission_id_123",
  "roles": ["write"],
  "grantedToV2": {
    "user": {
      "email": "user@example.com"
    }
  },
  "inheritedFrom": {
    "driveId": "DRIVE_ID",
    "id": "PARENT_FOLDER_ID",
    "path": "/drives/DRIVE_ID/root:/Parent Folder"
  }
}
```

**Unique/Specific Permission:**
```json
{
  "id": "permission_id_456",
  "roles": ["read"],
  "grantedToV2": {
    "user": {
      "email": "otheruser@example.com"
    }
  }
}
```

### Detection Logic

**If `inheritedFrom` field is present:** Permission is inherited from another folder (specified in the field)

**If `inheritedFrom` field is absent:** Permission is unique/specific to this folder

### Implementation

```tcl
proc is_inherited_permission {perm} {
    # Check if permission is inherited
    return [dict exists $perm inheritedFrom]
}
```

## Folder-Level Inheritance Status

### OneDrive Personal (Consumer)

**No direct API field exists** to indicate if a folder has broken inheritance.

You must **infer the status** by analyzing all permissions on the folder:

#### Analysis Rules

**1. All permissions are inherited:**
```
Total permissions: 5
Inherited: 5
Unique: 0
→ Status: INHERITING (folder inherits from parent)
```

**2. No permissions are inherited:**
```
Total permissions: 8
Inherited: 0
Unique: 8
→ Status: BROKEN INHERITANCE (folder has unique permissions)
```

**3. Mixed inherited and unique:**
```
Total permissions: 6
Inherited: 5
Unique: 1
→ Status: PARTIAL (some inherited, some unique)
```

#### Detection Implementation

```tcl
proc analyze_folder_inheritance {permissions} {
    set total [llength $permissions]
    set inherited 0

    foreach perm $permissions {
        if {[dict exists $perm inheritedFrom]} {
            incr inherited
        }
    }

    set unique [expr {$total - $inherited}]

    if {$inherited == 0 && $unique > 0} {
        return "broken"
    } elseif {$inherited > 0 && $unique == 0} {
        return "inheriting"
    } else {
        return "mixed"
    }
}
```

### OneDrive for Business (SharePoint-backed)

**Direct API field available** via SharePoint REST API.

#### Property: HasUniqueRoleAssignments

**true** = Folder has broken inheritance (unique permissions)
**false** = Folder inherits permissions from parent

#### Access Methods

**Via SharePoint REST API:**
```
GET {siteUrl}/_api/web/lists(guid'{listId}')/items({itemId})/HasUniqueRoleAssignments
```

**Via Graph API (SharePoint sites):**
```
GET /sites/{siteId}/lists/{listId}/items/{itemId}?$select=fields&$expand=fields
```

**Via Graph API (OneDrive items with SharePoint backend):**
```
GET /me/drive/items/{itemId}
```

Check response for `sharepointIds` object - if present, can access SharePoint REST API.

#### Detecting OneDrive Type

**OneDrive Personal:**
- `driveType: "personal"`
- No `sharepointIds` in item metadata
- `webUrl` contains `onedrive.live.com`

**OneDrive for Business:**
- `driveType: "business"`
- Contains `sharepointIds` with `siteId`, `listId`, `listItemId`
- `webUrl` contains SharePoint domain

### Example Detection

```tcl
proc get_inheritance_status {item_id access_token} {
    # Get item metadata
    set item_url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id"
    set item_data [make_http_request $item_url [list Authorization "Bearer $access_token"]]
    set item [json::json2dict [lindex $item_data 1]]

    # Check if OneDrive for Business
    if {[dict exists $item sharepointIds]} {
        # Can use SharePoint REST API for HasUniqueRoleAssignments
        # (Implementation depends on SharePoint access)
        return "business"
    }

    # OneDrive Personal - analyze permissions
    set perms_url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id/permissions"
    set perms_data [make_http_request $perms_url [list Authorization "Bearer $access_token"]]
    set permissions_dict [json::json2dict [lindex $perms_data 1]]
    set permissions [dict get $permissions_dict value]

    return [analyze_folder_inheritance $permissions]
}
```

## Special Cases

### Phantom Inheritance

**Symptom:** Permission shows `inheritedFrom` pointing to non-existent folder ID

**Detection:**
```tcl
proc is_phantom_inheritance {perm access_token} {
    if {![dict exists $perm inheritedFrom]} {
        return 0
    }

    set source_id [dict get $perm inheritedFrom id]
    set check_url "https://graph.microsoft.com/v1.0/me/drive/items/$source_id"
    set result [make_http_request $check_url [list Authorization "Bearer $access_token"]]
    set status [lindex $result 0]

    # If source returns 404, it's a phantom
    return [expr {$status eq "404"}]
}
```

**Indicators:**
- `inheritedFrom.id` returns HTTP 404 when queried
- Often has "se" prefix in ID (e.g., `5D1B2B3BE100F93B!se100f93b...`)
- Permission cannot be deleted via Graph API
- See `PHANTOM-INHERITANCE-BUG.md` for details

### Link Permissions

**Shared link permissions** may not have `inheritedFrom` but are not unique to the folder:

```json
{
  "id": "link_id",
  "roles": ["read"],
  "link": {
    "scope": "anonymous",
    "type": "view",
    "webUrl": "https://..."
  }
}
```

**Detection:**
```tcl
proc is_link_permission {perm} {
    return [dict exists $perm link]
}
```

### Owner Permissions

**Owner permissions** are special and should be excluded from inheritance analysis:

```tcl
proc is_owner_permission {perm} {
    if {![dict exists $perm roles]} {
        return 0
    }
    set roles [dict get $perm roles]
    return [expr {[lsearch -exact $roles "owner"] >= 0}]
}
```

## Summary Table

| Scenario | inheritedFrom Field | Folder Status | Can Delete via API |
|----------|-------------------|---------------|-------------------|
| Inherited permission | Present, valid ID | Inheriting | No |
| Unique permission | Absent | Broken inheritance | Yes |
| Phantom inherited | Present, 404 ID | Broken (corrupted) | No |
| Link permission | Absent, has `link` | N/A | Yes |
| Owner permission | Absent | N/A | No |

## Tool Implementation

The acl-manager tool uses `is_inherited_permission` (line 624) and `has_explicit_user_permission` (line 2660) to:

1. Skip inherited permissions when removing users (Graph API limitation)
2. Filter results to show only explicit/unique permissions
3. Detect phantom inheritance scenarios

**Key Functions:**
- `is_inherited_permission` - Check if single permission is inherited
- `has_explicit_user_permission` - Check if user has non-inherited permission
- `is_owner_permission` - Exclude owner from removal operations

## References

### Microsoft Documentation
- [Permission resource type - Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/resources/permission?view=graph-rest-1.0)
- [List permissions - Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/driveitem-list-permissions?view=graph-rest-1.0)
- [SharePoint REST API - Permissions](https://sharepointcass.com/2021/04/22/sharepoint-online-rest-apis-part-vi-permissions/)

### SharePoint-Specific
- [Check if folder has unique permissions](https://sharepoint.stackexchange.com/questions/263633/check-folder-has-unique-permissions)
- [SharePoint Online: Check If a Folder has Unique Permissions](https://www.sharepointdiary.com/2019/06/sharepoint-online-check-if-folder-has-unique-permissions.html)
- [Check if SharePoint Objects has unique permission from REST API](https://siddharthvaghasia.com/check-if-sharepoint-objects-has-unique-permission-from-rest-api/)

## See Also

- `PHANTOM-INHERITANCE-BUG.md` - Detailed explanation of phantom inheritance bug and workaround
- `TOKEN-IMPLEMENTATION.md` - Token management and API access
