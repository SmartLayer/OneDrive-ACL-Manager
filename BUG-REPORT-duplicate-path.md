# Bug Report: Duplicate Folder Path Navigation Issue

## Summary
When navigating through folders in the GUI, certain folders appear as their own children, causing path duplication (e.g., `🇬🇪 I.E. Digital Services/🇬🇪 I.E. Digital Services`). This leads to 404 errors when attempting to fetch ACL information.

## Severity
Medium - Affects navigation and ACL inspection for specific folders, but doesn't crash the application.

## Occurrence
- **Frequency**: Intermittent/Random
- **Affected Folders**: 
  - `🇬🇪 I.E. Digital Services` (ID: `5D1B2B3BE100F93B!safaa0cec07ab4ddd9843842d9db1ac6a`)
  - Potentially others (not yet identified)

## Steps to Reproduce
1. Launch the GUI: `wish acl-inspector.tcl`
2. Navigate to root folder
3. Click on `🇬🇪 I.E. Digital Services` folder
4. Observe that the folder listbox shows a subfolder with the same name: `🇬🇪 I.E. Digital Services`
5. Click on this subfolder
6. Path becomes: `🇬🇪 I.E. Digital Services/🇬🇪 I.E. Digital Services`
7. Error occurs: 404 itemNotFound

## Expected Behaviour
- Folders should only appear once in the hierarchy
- Navigation should not create duplicate path segments
- Only legitimate subfolders should be displayed in the folder listbox

## Actual Behaviour
- Some folders appear as their own children in the folder listbox
- Clicking on these entries duplicates the folder name in the path
- The folder ID remains identical (confirming it's the same folder, not a subfolder)
- Microsoft Graph API returns 404 when trying to access the duplicated path

## Technical Details

### Evidence from Logs
```
Line 96:  GUI: Loading folder contents - ID: '5D1B2B3BE100F93B!safaa0cec07ab4ddd9843842d9db1ac6a', Path: '🇬🇪 I.E. Digital Services'
Line 107: GUI: Loading folder contents - ID: '5D1B2B3BE100F93B!safaa0cec07ab4ddd9843842d9db1ac6a', Path: '🇬🇪 I.E. Digital Services/🇬🇪 I.E. Digital Services'
```

**Key Observation**: The folder ID is identical before and after navigation, proving it's the same folder appearing as its own child.

### rclone Verification
```bash
$ rclone lsd "OneDrive:🇬🇪 I.E. Digital Services"
          -1 2025-10-15 00:41:03         2 Banking
```

**Important**: `rclone lsd` shows only one legitimate subfolder (`Banking`), NOT a duplicate of the parent folder. This suggests:
- The issue is specific to how the Microsoft Graph API returns children
- rclone filters out or doesn't receive the problematic entry
- The circular reference exists at the API level

### API Request
The problematic folder listing comes from:
```
https://graph.microsoft.com/v1.0/me/drive/items/5D1B2B3BE100F93B!safaa0cec07ab4ddd9843842d9db1ac6a/children
```

## Hypothesis

### ❌ DISPROVEN: OneDrive Shortcut/Circular Reference
**Initial hypothesis**: The Microsoft Graph API is returning a child item that references the parent folder itself.

**Verification Result**: **DISPROVEN** - rclone verification shows NO circular reference in the API data.

The `rclone lsd` command showed only legitimate children:
```bash
$ rclone lsd "OneDrive:🇬🇪 I.E. Digital Services"
          -1 2025-10-15 00:41:03         2 Banking
```

**Conclusion**: The API is NOT returning the folder as its own child. The duplicate path problem must be caused by a bug in our navigation/folder listing code, NOT by the OneDrive API or circular references.

### Current Working Hypothesis: Code Bug in Folder Navigation
Since rclone shows the correct data (no duplicates), but our GUI shows duplicates, the bug must be in one of these areas:

1. **Folder listbox population logic** - Perhaps folders are being added twice
2. **Navigation state management** - Current folder info might persist incorrectly
3. **Event handling** - Click events might be firing incorrectly
4. **Folder name matching** - Navigation code might be matching the wrong folder

### Supporting Evidence
- Folder ID remains identical (same folder, not a subfolder)
- rclone shows correct data (proves API is fine)
- The issue is intermittent (suggests race condition or state management issue)
- No DEBUG output appeared when navigating to the problematic folder (debug condition may not be matching correctly)

## Code Location

### Where the Problem Occurs
**File**: `acl-inspector.tcl`

**Function**: `fetch_remote_folder_contents` (lines 235-320)

**Problematic Section** (lines 298-303):
```tcl
foreach child $children {
    if {[dict exists $child folder]} {
        set child_name [dict get $child name]
        $folder_listbox insert end $child_name
    }
}
```

**Issue**: The code blindly adds all children with a `folder` key without checking:
- If `child_id == current_folder_id` (circular reference)
- If the child has a `remoteItem` field (indicates shortcut)
- If the child is a legitimate subfolder or a link/reference

## Investigation Steps

### 1. Enable Comprehensive Listbox Debug Logging
The DEBUG code at lines 281-296 was supposed to trigger but didn't produce output. We need better logging:

```tcl
# In fetch_remote_folder_contents, replace the foreach loop at line 298:
puts "DEBUG: ===== Populating listbox for folder ID: $folder_id ====="
puts "DEBUG: Current path: $current_folder_path"
puts "DEBUG: Total children from API: [llength $children]"

set folder_count 0
foreach child $children {
    if {[dict exists $child folder]} {
        set child_name [dict get $child name]
        set child_id [dict get $child id]
        puts "DEBUG: [$folder_count] name='$child_name' id='$child_id'"
        $folder_listbox insert end $child_name
        incr folder_count
    }
}

puts "DEBUG: Finished adding $folder_count folders to listbox"
puts "DEBUG: ===== End listbox population ====="
```

### 2. Add Navigation Tracking
Track what folder name is clicked and what ID it resolves to:

```tcl
# In find_and_navigate_to_folder, add at the start:
puts "DEBUG: ===== NAVIGATION ATTEMPT ====="
puts "DEBUG: Looking for folder name: '$folder_name'"
puts "DEBUG: Current folder ID: $current_folder_id"
puts "DEBUG: Current folder path: $current_folder_path"
```

### 3. Check Listbox State Before Click
When the bug occurs, manually inspect what's in the listbox to confirm if the duplicate is really there or if it's a navigation/event issue.

## Suggested Fixes

**Note**: Since rclone verification proved the API data is correct, the fixes should focus on the code logic, not filtering API responses.

### Option 1: Add Defensive Check - Prevent Circular Navigation (Safest Quick Fix)
Even though the API isn't returning circular references, we should prevent the folder ID from being navigated to if it matches the current folder:

```tcl
# In find_and_navigate_to_folder, before calling load_folder_contents:
if {$child_id eq $current_folder_id} {
    puts "DEBUG: Attempted to navigate to same folder - skipping"
    update_status "Cannot navigate: folder references itself" yellow
    return
}
load_folder_contents $child_id $new_path
```

### Option 2: Debug Folder Listbox Population
Add comprehensive logging to understand what's being added to the listbox:

```tcl
# In fetch_remote_folder_contents, replace the foreach loop:
puts "DEBUG: About to populate listbox for folder: $folder_id"
set idx 0
foreach child $children {
    if {[dict exists $child folder]} {
        set child_name [dict get $child name]
        set child_id [dict get $child id]
        puts "DEBUG: [$idx] Adding child: name='$child_name' id='$child_id'"
        $folder_listbox insert end $child_name
        incr idx
    }
}
puts "DEBUG: Listbox population complete. Total folders added: $idx"
```

### Option 3: Investigate Event Binding
Check if Button-1 binding is somehow causing the issue:

```tcl
# Current binding (line ~1206):
bind $folder_listbox <Button-1> {
    set selection [%W curselection]
    if {$selection ne ""} {
        set folder_name [%W get $selection]
        navigate_to_folder $folder_name
    }
}
```

Potential issue: This navigates on mouse down. Consider if this could cause issues with selection state.

## Workarounds

### For Users
1. Don't click on folders that have the same name as the current folder
2. Use the ".." navigation to go back if you accidentally enter a duplicate path
3. Use CLI mode with explicit paths instead of GUI navigation

### For Developers
Current debug code added at line 281-296 will help identify which folders have this issue.

## Related Issues
- Line 1187: Status message shows OneDrive URL which could be used for direct navigation
- The URL bar implementation (recent change) displays the correct URL based on folder ID, which remains correct even when path is wrong

## Next Steps
1. Run the application with DEBUG logging enabled
2. Navigate to `🇬🇪 I.E. Digital Services` and capture the full API response
3. Check if `remoteItem` field exists in the problematic child
4. Implement Option 1 or Option 2 based on findings
5. Test with multiple folders to ensure fix doesn't break normal navigation

## Date Reported
2025-10-22

## Reporter Notes
The issue appears random but is reproducible on specific folders. The fact that rclone doesn't show the duplicate suggests this is a known issue with OneDrive's API that rclone has already worked around.

