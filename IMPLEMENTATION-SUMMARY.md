# ACL Editing Implementation Summary

## Latest: 2025-10-23 (Recursive ACL Display)

This document summarises the successful implementation of ACL editing functionality in the OneDrive ACL Inspector with a task-oriented interface, improved OAuth authentication flow, and user-centric recursive ACL display.

## Latest Update: Recursive ACL Display (2025-10-23)

### User-Centric Recursive Permission Auditing

**New Procedures**:
- `extract_users_from_permissions()` - Extracts all non-owner users from a permissions list
- `get_user_role_from_permissions()` - Gets role for a specific user from permissions
- `compare_permission_sets()` - Compares child vs parent permissions to detect inheritance type
- `build_user_folder_map()` - Creates map of additional users (not in root) to their folder access
- `detect_special_folders()` - Identifies folders with non-inherited permissions
- `display_recursive_acl()` - Main display function with three-section output format
- `collect_folder_permissions_recursive()` - Recursively collects full permission data

**Key Features**:

1. **User-Centric Display**: Instead of listing folders with their permissions, the new format organizes by users:
   - Root folder permissions (users with access to the starting folder)
   - Additional users in subfolders (users who only appear in specific subfolders)
   - Special folders with non-inherited permissions

2. **Smart Inheritance Detection**: Automatically identifies folders with:
   - **EXTENDED**: Folders with additional users beyond the root (explicit grants)
   - **RESTRICTED**: Folders with fewer users than root (inheritance disabled)
   - **DIFFERENT**: Folders with completely different permission sets
   - **Inherited**: Normal folders (not listed separately to reduce noise)

3. **Unified Display Logic**: Non-recursive mode (no `-r` flag) uses the same display format, treating it as a special case with depth 0. This eliminates code duplication.

4. **Automatic Token Refresh**: Default ACL display now uses `get_access_token_with_capability()` for automatic token refresh when expired.

**Command-Line Usage**:
```bash
# Recursive scan with depth limit
./acl-inspector.tcl "Finance" -r --max-depth 2

# Non-recursive (single folder)
./acl-inspector.tcl "Finance"

# Deep audit
./acl-inspector.tcl "Projects" -r --max-depth 10
```

**Output Format**:
```
================================================================================
=== ACL for "Finance" (recursive scan, max depth: 2) ===
================================================================================

📊 Root Folder Permissions:
   • alice@example.com                                  (write)
   • bob@example.com                                    (read)
   • charlie@example.com                                (write)

📋 Additional Users in Subfolders:
   dave@example.com
      └─ Finance/Budget2025 (read)
      └─ Finance/Reports (write)

   eve@example.com
      └─ Finance/Confidential (write)

⚠️  Special Folders (Non-Inherited Permissions):
   📁 Finance/Confidential (RESTRICTED)
      • alice@example.com                              (write)
      • eve@example.com                                (write)
      ⚠️  Access removed: bob@example.com, charlie@example.com

--------------------------------------------------------------------------------
Summary: 5 unique user(s) across 1 root folder + 3 subfolder(s)
--------------------------------------------------------------------------------
```

**Design Benefits**:

1. **Answers "Who has access?" clearly**: The primary use case is auditing access, especially post-termination ("Did we revoke Bob's access everywhere?"). The user-centric format makes this trivial to answer.

2. **Highlights security issues**: Special folders section immediately shows where inheritance is disabled or modified, which are potential security concerns.

3. **Reduces noise**: Inherited folders (the common case) are not listed separately, focusing attention on exceptions.

4. **Scalable**: Works efficiently even with large folder hierarchies by focusing on users rather than folders.

**Technical Implementation**:

- Recursive collection stores complete permission data with parent tracking
- Permission comparison uses set operations to detect inheritance patterns
- Display logic handles both recursive (depth > 0) and non-recursive (depth = 0) modes uniformly
- Automatic token refresh prevents authentication errors during long scans

**Testing**: Tested successfully with real OneDrive folder containing 14 subfolders, 22 unique users, and 8 special folders with extended permissions.

## Latest Update: Modal OAuth Dialog (2025-10-22)

### Modal Authentication Dialog with Token Reload

**New Procedures**:
- `cleanup_oauth_server()` - Centralized OAuth server cleanup utility
- `oauth_modal_start_browser_auth()` - Initiates browser authentication when user clicks button
- `oauth_modal_check_completion()` - Non-blocking periodic checker using `after`
- `oauth_modal_reload_token()` - Token reload handler with validation
- `show_oauth_modal_dialog()` - Main modal dialog for authentication

**Key Improvements**:

1. **Two-Button Choice Design**: 
   - Dialog presents two clear action buttons: "Authenticate with Browser" and "Reload Token File"
   - Browser authentication only starts WHEN user clicks the button (not automatically)
   - User can choose whichever method suits their situation
   - Can close dialog to cancel (no destructive action taken by showing modal)

2. **Modal Blocking**: Dialog uses `grab set` to prevent user interaction with main window during authentication, eliminating race conditions and user errors

3. **Cross-PC Token Support**: "Reload Token File" button allows users to:
   - Authenticate on one computer
   - Copy token.json to another computer
   - Load the token without re-authenticating

4. **Token Validation**: Reload function validates:
   - Token file exists and is valid JSON
   - Token has required scopes (Files.ReadWrite.All + Sites.Manage.All)
   - Shows clear error messages for each failure mode
   - Re-enables button after errors for retry

5. **Race Condition Handling**: Detects when OAuth callback arrives while user is loading token, prevents conflicts

6. **Timeout Behavior**: After 120 seconds timeout, dialog stays open with option to reload token file rather than forcing user to restart

7. **Auto-Close on Success**: When authentication succeeds (via browser OR reload), dialog closes automatically - no confirmation click needed

8. **Better UX**:
   - Real-time status updates (elapsed time counter during browser auth)
   - Clear instructions about both authentication options
   - Automatic cleanup of OAuth server on success/failure/cancel
   - Progress feedback during token exchange

**Updated Procedures**:
- `acquire_elevated_token()` - Simplified to just show modal dialog
- `ensure_edit_capability()` - Removed redundant confirmation dialog, goes directly to modal

**Design Decisions**:

1. **Eliminated "Can I ask a question?" anti-pattern**
   - Before: Two dialogs (confirmation + modal with options)  
   - After: Single modal with both authentication options
   - Rationale: Nothing destructive happens by showing the modal, so confirmation is unnecessary

2. **No hardcoded window geometries**
   - All dialog windows (modal OAuth, invite user, etc.) have no `wm geometry` calls
   - Windows size themselves based on content and padding
   - Rationale: Users have different display scaling factors; hardcoded pixel dimensions become unusably small on high-DPI displays with scaling enabled
   - The window manager and Tk's layout system handle proper sizing automatically

3. **Global variable for event-driven communication**
   - Uses `oauth_modal_result` global variable for communication between callbacks and main dialog
   - Rationale: Button commands execute in global scope (event loop), not local procedure scope
   - Tried local variable with `upvar` but fails due to Tcl's event-driven architecture
   - Global variable initialized at top level (line 74) ensures it exists before any code runs

**Technical Challenges Overcome**:

1. **Variable Scope in Event Handlers**: Initial attempt used local variable with `upvar`, but button commands execute in global scope. Solution: Use global `oauth_modal_result` variable.

2. **WM_DELETE_WINDOW Interference**: When destroying modal on success, the window close protocol triggered and set `oauth(auth_code) = "CANCELLED"`, interfering with success flow. Solution: Disable `WM_DELETE_WINDOW` protocol before destroying window on success.

3. **Event-Driven vs Blocking**: Original code used blocking `while` loop with `update` calls, which doesn't truly block interaction. Solution: Use `after`-based non-blocking checks combined with `grab set` for true modal behavior.

## Features Implemented

### 1. UI Enhancements - Task-Oriented Design

**Action Buttons** (Lines 137-145):
- Located on the RIGHT SIDE of the fetch button frame
- Two buttons: "Remove Selected" and "Invite User"
- Always visible after fetching ACL
- Disabled by default, enabled when ACL is fetched
- Permission check happens when clicked

**Multi-Select Treeview** (Line 180):
- `selectmode extended` - supports Ctrl+Click and Shift+Click selection
- Allows selecting multiple permissions for bulk removal

### 2. Microsoft Graph API Operations

**Location**: Lines 959-1058

#### `invite_user_to_item(item_id, email, role, access_token)`
- POST to `/me/drive/items/{item_id}/invite`
- Supports "read" (view) and "write" (edit) roles
- Returns status and message

#### `remove_permission(item_id, permission_id, access_token)`
- DELETE to `/me/drive/items/{item_id}/permissions/{permission_id}`
- Handles 204 (success), 403 (forbidden), 404 (not found), 401 (expired token)

#### `strip_explicit_permissions(item_id, access_token)`
- Removes all non-owner, non-inherited permissions
- Returns count of removed permissions
- Skips owner and inherited entries automatically

**HTTP Method Support**: Enhanced `make_http_request()` to support GET, POST, DELETE methods (Lines 916-948)

### 3. Just-In-Time Permission Checking

**Location**: Lines 1060-1095

#### `ensure_edit_capability()`
- **Key function** - called by all action buttons before performing operations
- Checks current token capability
- If "full" → returns immediately (allows operation)
- If "read-only" or "unknown":
  - Shows dialog: "This operation requires elevated OneDrive permissions. Authenticate?"
  - If yes → launches OAuth flow
  - If no or failed → returns 0 (cancels operation)
- Returns 1 if user has or acquires edit capability, 0 otherwise

**Usage Pattern**:
```tcl
proc on_invite_user_click {} {
    # Check item selected
    if {$current_item_id eq ""} { ... return }
    
    # Check permission (prompts for OAuth if needed)
    if {![ensure_edit_capability]} { return }
    
    # Proceed with operation...
}
```

### 4. Interactive Dialogs and Handlers

**Location**: Lines 1097-1284

#### `on_invite_user_click()`
- Checks if item selected
- **Calls `ensure_edit_capability()`** - may prompt for OAuth
- Shows custom dialog with:
  - Email address entry field
  - Radio buttons for read/write permission
  - OK/Cancel buttons
- Validates email input
- Calls `invite_user_to_item()` API
- Refreshes ACL display on success

#### `on_remove_selected_click()`
- Checks if item selected
- Gets selected items from treeview
- Validates no owner permissions selected
- **Calls `ensure_edit_capability()`** - may prompt for OAuth
- Shows confirmation dialog with count
- Bulk removes selected permissions
- Reports success/failure counts

### 5. Error Handling and User Feedback

**Status Messages**:
- Token capability displayed: "Using token (capability: full/read-only)"
- Operation progress: "Removing 3 permission(s)..."
- Success: "✅ Removed 3 permission(s)"
- Warnings: "⚠️ Removed 2, failed 1"
- Errors: "❌ Token expired - please try again"

**Token Expiry Handling**:
- 401 responses show "Token expired - please try again"
- User can click the button again to re-authenticate

**API Error Codes**:
- 401 Unauthorized → Token expired, prompt to try again
- 403 Forbidden → Insufficient permissions
- 404 Not Found → Item/permission not found
- 429 Rate Limit → Handled in HTTP request wrapper

### 6. Integration Points

#### `fetch_acl()` Enhancement (Lines 1746-1904)
- Now uses `get_access_token_with_capability()` instead of `get_access_token()`
- Stores `current_item_id` for edit operations
- **Enables action buttons** when ACL is successfully fetched
- Displays token capability in status message

#### Startup (Lines 1906-1917)
- Checks token capability on launch
- Displays appropriate status message based on available permissions

#### `refresh_current_acl()` Helper (Lines 1286-1293)
- Automatically refreshes ACL display after modifications
- Uses stored `selected_item` path

## Testing Checklist

### OAuth Flow
- [ ] Click "Invite User" with read-only token → OAuth prompt appears
- [ ] Click "Remove Selected" with read-only token → OAuth prompt appears
- [ ] Browser opens with correct URL
- [ ] Callback server receives authorization code
- [ ] Token exchanged and saved to token.json
- [ ] Operation proceeds after authentication

### Edit Operations
- [ ] Invite user with read permission
- [ ] Invite user with write permission
- [ ] Remove single permission
- [ ] Remove multiple permissions (multi-select)
- [ ] Owner permissions cannot be removed (validation)
- [ ] ACL refreshes after successful operations

### User Flow
- [ ] User clicks "Invite" with full token → dialog appears immediately
- [ ] User clicks "Invite" with read-only token → OAuth prompt, then dialog
- [ ] User cancels OAuth → operation cancelled, no error
- [ ] Token expired during operation → error shown, can retry

### Error Scenarios
- [ ] Token expired (401) → shows "try again" message
- [ ] Insufficient permissions (403) → shows error
- [ ] Invalid email → validation prevents API call
- [ ] Network errors handled gracefully

## Files Modified

1. `acl-inspector.tcl` - Main application file
   - Added ~1000 lines of ACL editing functionality
   - No breaking changes to existing CLI mode
   - GUI mode enhanced with task-oriented edit capabilities

## Usage Instructions

### For Read-Only Access (Default)
1. Launch application: `wish acl-inspector.tcl`
2. Browse OneDrive folders in multi-column view
3. Select item and click "Fetch ACL"
4. View permissions in treeview

### For ACL Editing
1. After fetching ACL, action buttons appear on the right
2. Click "Invite User" or "Remove Selected" as needed
3. If elevated permissions are required:
   - Authentication dialogue appears automatically
   - Choose "Authenticate with Browser" or "Reload Token File"
   - For browser authentication: sign in to Microsoft account
   - Token saved to token.json automatically
   - Operation proceeds after authentication
4. Subsequent operations use the saved token

## Security Considerations

1. **Token Storage**: token.json created with 0600 permissions (owner read/write only)
2. **Scope Principle**: Only requests necessary scopes for ACL editing
3. **Confirmation Dialogs**: Destructive operations require user confirmation
4. **Owner Protection**: Cannot remove owner permissions (enforced in UI)
5. **Just-In-Time Auth**: OAuth only triggered when actually needed

## Known Limitations

1. Token expiry is checked lazily (only when performing operations)
2. Microsoft personal accounts may have limited `Sites.Manage.All` support
3. OAuth flow requires local port 53682 to be available
4. Inherited permissions cannot be removed (by design)

## Critical Implementation Notes

### ⚠️ Tcl catch/return Gotcha (CRITICAL)

**Problem**: In Tcl, `catch` catches **ALL non-local control flow**, not just errors. This includes:
- `error` commands
- **`return` statements** ← This is the gotcha!
- `break` commands
- `continue` commands

**Wrong Pattern** (will fail):
```tcl
if {[catch {
    # ... some code ...
    if {$some_condition} {
        return $value  # ❌ This return is CAUGHT as an error!
    }
} error]} {
    puts "Error: $error"  # Will catch the return as error code!
}
```

**Correct Pattern**:
```tcl
set result ""
set has_error 0

if {[catch {
    # ... some code ...
    if {$some_condition} {
        set result $value  # ✓ Set variable instead
    }
} error] != 0} {
    puts "Error: $error"
    set has_error 1
}

# Return AFTER the catch block
if {$has_error} {
    return ""
}
return $result
```

**Why This Matters**: During implementation, we encountered multiple failures where `return` statements inside catch blocks were being caught as errors. This caused:
- OAuth token exchange to fail with "Token exchange failed: 1" (the return code)
- Functions to report errors when they actually succeeded
- Debugging confusion as error messages showed return values instead of actual errors

**Fixed Functions**:
- `get_access_token()` - Lines ~632-642
- `oauth_handle_request()` - Lines ~835-907
- `oauth_exchange_token()` - Lines ~925-994
- `acquire_elevated_token()` - Lines ~1008-1029, ~1050-1065, ~1079-1106
- `get_item_path()` - Lines ~1545-1595

**Rule of Thumb**: Never use `return` inside a `catch` block. Always set a variable and return after the catch completes.

## Future Enhancements

Potential improvements not implemented in this version:

1. Token refresh using refresh_token (currently requires re-authentication)
2. Permission expiration date editing
3. Bulk invite multiple users at once
4. Export/import ACL configurations
5. Visual indicators for inherited vs explicit permissions

## References

- Microsoft Graph API Documentation: https://learn.microsoft.com/en-us/graph/api/driveitem-invite
- Microsoft OAuth 2.0 Documentation: https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-auth-code-flow
- Tcl catch Documentation: https://www.tcl.tk/man/tcl8.6/TclCmd/catch.html
- Token Authentication Design: See `TOKEN-IMPLEMENTATION.md` for detailed token management architecture
