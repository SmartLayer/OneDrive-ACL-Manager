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

### Current Working Hypothesis: Race Condition with ACL Fetch

**NEW HYPOTHESIS (2025-10-22)**: The duplicate path issue is caused by a race condition between folder navigation and the automatic ACL fetch that takes ~2 minutes.

#### How the Race Condition Occurs:

1. **User clicks on Folder A**
   - `navigate_to_folder("A")` is called (line 1283)
   - `find_and_navigate_to_folder("A")` makes API call using current `current_folder_id` (line 459-463)
   - `load_folder_contents(A_id, "A")` updates globals: `current_folder_id = A_id`, `current_folder_path = "A"` (line 277-278)
   - `fetch_remote_folder_contents(A_id)` fetches children and populates listbox (line 303)
   - **`fetch_acl_for_current_folder()` is called and takes ~2 minutes** (line 377)

2. **User clicks on Folder B before ACL fetch completes**
   - Same sequence happens for Folder B
   - Updates `current_folder_id = B_id`, `current_folder_path = "B"`
   - Starts another 2-minute ACL fetch

#### Why This Causes Duplicate Paths:

The issue may be related to:

1. **Event Queue Blocking**: The 2-minute ACL fetch blocks the UI, causing clicks to queue up or be processed incorrectly
2. **Stale API Responses**: If `find_and_navigate_to_folder` makes an API call but the response arrives after the user has clicked another folder, it might use stale `current_folder_id`
3. **Multiple API Calls**: Line 303 (`fetch_remote_folder_contents`) and line 459 (`find_and_navigate_to_folder`) both make API calls to get children - if these overlap, folder listbox might get populated twice

#### Code Flow Analysis:

```tcl
# Line 1279: Click binding
bind $folder_listbox <Button-1> {
    navigate_to_folder $folder_name
}

# Line 390: navigate_to_folder calls
find_and_navigate_to_folder $folder_name

# Line 451-492: find_and_navigate_to_folder
- Makes API call: /items/$current_folder_id/children (ASYNC)
- When response arrives, calls load_folder_contents

# Line 268-304: load_folder_contents
- Updates global: current_folder_id, current_folder_path (IMMEDIATE)
- Calls fetch_remote_folder_contents (ASYNC)
- Calls fetch_acl_for_current_folder (BLOCKS FOR 2 MINUTES)
```

### Supporting Evidence
- Folder ID remains identical (same folder, not a subfolder)
- rclone shows correct data (proves API is fine)
- The issue is intermittent (suggests race condition or state management issue)
- The ACL fetch takes 2 minutes, providing ample time for race conditions
- No DEBUG output appeared when navigating to the problematic folder (debug condition may not be matching correctly)
- Issue occurs when "you proceed to click other folder before the \[ACL\] result was fetched" (user observation)

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

**Note**: Since rclone verification proved the API data is correct, the fixes should focus on the code logic, not filtering API responses. The primary issue is the race condition caused by the blocking 2-minute ACL fetch.

### **Option 1: Make ACL Fetch Asynchronous (RECOMMENDED)**
The root cause is that `fetch_acl` blocks for 2 minutes. We should make it non-blocking:

```tcl
# In fetch_remote_folder_contents, line 377, change from:
fetch_acl_for_current_folder

# To async approach with after:
after 10 fetch_acl_for_current_folder
```

This allows the UI to remain responsive and prevents event queue buildup.

**Alternative**: Add a flag to prevent navigation during ACL fetch:

```tcl
# Add global variable:
set acl_fetch_in_progress 0

# In fetch_acl_for_current_folder, wrap the call:
proc fetch_acl_for_current_folder {} {
    global acl_fetch_in_progress
    if {$acl_fetch_in_progress} {
        debug_log "ACL fetch already in progress, skipping"
        return
    }
    set acl_fetch_in_progress 1
    after 10 {
        fetch_acl $current_folder_path
        set acl_fetch_in_progress 0
    }
}

# In navigate_to_folder, add check:
if {$acl_fetch_in_progress} {
    update_status "Please wait for ACL fetch to complete" yellow
    return
}
```

### **Option 2: Cancel Pending ACL Fetch on Navigation**
When user navigates to a new folder, cancel any pending ACL fetch:

```tcl
# Add global variable:
set acl_fetch_job ""

# In fetch_acl_for_current_folder:
proc fetch_acl_for_current_folder {} {
    global acl_fetch_job current_folder_path
    
    # Cancel any pending ACL fetch
    if {$acl_fetch_job ne ""} {
        after cancel $acl_fetch_job
        debug_log "Cancelled pending ACL fetch"
    }
    
    # Schedule new ACL fetch with slight delay
    set acl_fetch_job [after 500 [list fetch_acl $current_folder_path]]
}
```

### **Option 3: Add Defensive Check - Prevent Duplicate API Calls**
Prevent making the same API call twice if folder ID hasn't changed:

```tcl
# Add global variable to track last fetched folder:
set last_fetched_folder_id ""

# In fetch_remote_folder_contents, add check at start:
proc fetch_remote_folder_contents {folder_id} {
    global last_fetched_folder_id
    
    if {$folder_id eq $last_fetched_folder_id} {
        debug_log "Already fetched contents for folder $folder_id, skipping"
        return
    }
    set last_fetched_folder_id $folder_id
    
    # ... rest of function
}
```

### Option 4: Add Navigation Guard - Prevent Circular Navigation
Even though the API isn't returning circular references, we should prevent the folder ID from being navigated to if it matches the current folder:

```tcl
# In find_and_navigate_to_folder, before calling load_folder_contents:
if {$child_id eq $current_folder_id} {
    debug_log "Attempted to navigate to same folder - skipping"
    update_status "Cannot navigate: folder references itself" yellow
    return
}
load_folder_contents $child_id $new_path
```

### Option 5: Debounce Click Events
Prevent rapid-fire clicks from causing race conditions:

```tcl
# Add global variables:
set last_navigation_time 0
set navigation_debounce_ms 500

# In navigate_to_folder, add debounce:
proc navigate_to_folder {folder_name} {
    global last_navigation_time navigation_debounce_ms
    
    set current_time [clock milliseconds]
    if {$current_time - $last_navigation_time < $navigation_debounce_ms} {
        debug_log "Navigation debounced - too soon after last navigation"
        return
    }
    set last_navigation_time $current_time
    
    # ... rest of function
}
```

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

