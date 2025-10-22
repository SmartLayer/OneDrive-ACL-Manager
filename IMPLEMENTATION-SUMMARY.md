# ACL Editing Implementation Summary

## Completed: 2025-10-22 (Revised for better UX)

This document summarizes the successful implementation of ACL editing functionality in the OneDrive ACL Inspector with a task-oriented, modeless interface.

## Features Implemented

### 1. Token Management with Capability Detection

**Location**: Lines 624-739

- `check_token_capability()` - Parses scope field from token.json to determine "full" vs "read-only" capability
- `get_access_token_with_capability()` - Checks token.json first (with scope validation), falls back to rclone.conf
- `save_token_json()` - Saves OAuth token response with proper format including scope field

**Key Behavior**:
- Token expiry is checked lazily (just-in-time) during API operations, not proactively when loading
- token.json with `Sites.Manage.All` + `Files.ReadWrite*` scopes → "full" capability
- rclone.conf tokens → "read-only" capability (no scope information available)

### 2. OAuth Flow for Token Acquisition

**Location**: Lines 741-914

- `oauth_start_local_server()` - Starts HTTP server on port 53682
- `oauth_accept()` - Handles OAuth callback, extracts authorization code
- `oauth_build_auth_url()` - Builds Microsoft authorization URL with required scopes
- `oauth_exchange_token()` - Exchanges authorization code for access token
- `acquire_elevated_token()` - Orchestrates full OAuth flow with 2-minute timeout

**OAuth Configuration**:
```tcl
Client ID: b15665d9-eda6-4092-8539-0eec376afd59
Scopes: Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access
Redirect URI: http://localhost:53682/
```

**Browser Support**: Cross-platform browser launch (Windows, macOS, Linux)

### 3. UI Enhancements - Task-Oriented Design (NO MODES!)

**Action Buttons** (Lines 137-145):
- Located on the RIGHT SIDE of the fetch button frame
- Two buttons: "Remove Selected" and "Invite User"
- **Always visible** after fetching ACL (no mode switching)
- Disabled by default, enabled when ACL is fetched
- Permission check happens **when clicked** - transparent to user

**Design Philosophy**:
- **No "Edit Mode"** - users don't need to understand or manage modes
- Just click what you want to do, and the app checks permissions
- If elevated permission needed, OAuth dialog appears automatically
- Much better UX - task-oriented rather than mode-oriented

**Multi-Select Treeview** (Line 180):
- `selectmode extended` - supports Ctrl+Click and Shift+Click selection
- Allows selecting multiple permissions for bulk removal

### 4. Microsoft Graph API Operations

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

### 5. Just-In-Time Permission Checking

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

### 6. Interactive Dialogs and Handlers

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

### 7. Error Handling and User Feedback

**Status Messages**:
- Token capability displayed: "Using token (capability: full/read-only)"
- Operation progress: "Removing 3 permission(s)..."
- Success: "✅ Removed 3 permission(s)"
- Warnings: "⚠️ Removed 2, failed 1"
- Errors: "❌ Token expired - please try again"

**Token Expiry Handling**:
- 401 responses show "Token expired - please try again"
- User can click the button again to re-authenticate
- No need to manually manage modes

**API Error Codes**:
- 401 Unauthorized → Token expired, prompt to try again
- 403 Forbidden → Insufficient permissions
- 404 Not Found → Item/permission not found
- 429 Rate Limit → Handled in HTTP request wrapper

### 8. Integration Points

#### `fetch_acl()` Enhancement (Lines 1746-1904)
- Now uses `get_access_token_with_capability()` instead of `get_access_token()`
- Stores `current_item_id` for edit operations
- **Enables action buttons** when ACL is successfully fetched
- Displays token capability in status message

#### Startup (Lines 1906-1917)
- Checks token capability on launch
- Displays appropriate status message:
  - "✅ Elevated token detected - Edit Mode available"
  - "ℹ️ Using read-only token - Authenticate for Edit Mode"
  - "⚠️ Unknown token capability"

#### `refresh_current_acl()` Helper (Lines 1286-1293)
- Automatically refreshes ACL display after modifications
- Uses stored `selected_item` path

## Design Decisions

### Why No "Edit Mode"?

The original design had an "Edit Mode" button that users had to click to enable editing. This was poor UX because:

1. **Users have to understand modes** - cognitive overhead
2. **Extra step** - click "Edit Mode" before doing anything
3. **Unclear state** - "Am I in edit mode? What mode am I in?"
4. **Not task-oriented** - users think "I want to invite a user", not "I need to enter edit mode"

### Better Design: Just-In-Time Permission Check

The revised design:

1. **Action buttons always visible** (after fetching ACL)
2. **Click what you want to do** - "Invite User", "Remove Selected"
3. **App checks permissions automatically** when button clicked
4. **OAuth prompt only if needed** - transparent to user
5. **No mental model of modes** - just direct action

This is **much more intuitive** and follows modern UX principles.

## Testing Checklist

### Token Management
- [x] Load token from token.json with valid scope → "full" capability
- [x] Fallback to rclone.conf when token.json missing → "read-only"
- [x] Token capability displayed on startup and after fetch

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
   - Added ~1000 lines of new functionality
   - Removed mode-based design (~200 lines)
   - No breaking changes to existing CLI mode
   - GUI mode enhanced with task-oriented edit capabilities

## Usage Instructions

### For Read-Only Access (Default)
1. Launch application: `wish acl-inspector.tcl`
2. Browse OneDrive folders in multi-column view
3. Select item and click "Fetch ACL"
4. View permissions in treeview

### For ACL Editing (Seamless, No Modes!)
1. After fetching ACL, action buttons appear on the right
2. Click "Invite User" or "Remove Selected" as needed
3. If you have elevated token → operation proceeds immediately
4. If you have read-only token:
   - Dialog prompts: "This operation requires elevated permissions. Authenticate?"
   - Click "Yes" to open browser
   - Sign in to Microsoft account
   - Token saved to token.json automatically
   - Operation proceeds after authentication
5. Next time you click an action → no prompt (you already have the token)

**No mode switching needed!** Just click what you want to do.

### Token Files
- `token.json` - Elevated token with editing permissions (short-lived)
- `~/.config/rclone/rclone.conf` - Fallback read-only token

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

### Token File Formats

**token.json** (created by OAuth flow):
```json
{
  "access_token": "EwA4BMl6BAAUBKgm8k1UswUNwklmy2v7...",
  "token_type": "Bearer",
  "expires_at": "2025-10-23T10:30:00Z",
  "scope": "Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access",
  "expires_in": 3599,
  "refresh_token": "M.C547_BL2.0.U.-CrM4qrpqFlFUlgCyy*vjky...",
  "drive_id": "5D1B2B3BE100F93B",
  "drive_type": "personal"
}
```

**Key Points**:
- **Must include `scope` field** for capability detection
- Uses `json::write` module (NOT `json::dict2json` which has quoting issues)
- File permissions: 0600 (owner read/write only)

**rclone.conf token** (fallback):
- Located: `~/.config/rclone/rclone.conf`
- **Does NOT contain scope field** - always treated as "read-only"
- Cannot determine capabilities from rclone tokens
- Microsoft OneDrive tokens are NOT standard JWTs and cannot be decoded

### Capability Detection Logic

**Method 1: Check scope in token.json** (Preferred)
- Parse `scope` field from token.json
- Look for: `Sites.Manage.All` AND (`Files.ReadWrite` OR `Files.ReadWrite.All`)
- If both present → "full" capability
- If only read scopes → "read-only"

**Method 2: Token source heuristic** (Fallback)
- token.json → assume "full" (user explicitly acquired it)
- rclone.conf → assume "read-only" (standard rclone permissions)

**Why NOT decode JWT**: Microsoft OneDrive tokens use proprietary format, not standard JWT. Cannot decode to extract claims.

## Future Enhancements

Potential improvements not implemented in this version:

1. Token refresh using refresh_token (currently requires re-authentication)
2. Permission expiration date editing
3. Bulk invite multiple users at once
4. Export/import ACL configurations
5. Visual indicators for inherited vs explicit permissions
6. "Strip Explicit" button (removed to simplify UI - can be added back if needed)

## References

- Microsoft Graph API Documentation: https://learn.microsoft.com/en-us/graph/api/driveitem-invite
- Microsoft OAuth 2.0 Documentation: https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-auth-code-flow
- Tcl catch Documentation: https://www.tcl.tk/man/tcl8.6/TclCmd/catch.html
