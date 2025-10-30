# Token Expiration Handling Implementation

## Summary of Changes

This implementation adds comprehensive token expiration checking with automatic refresh support and intelligent fallback logic for both CLI and GUI modes.

## New Functions Added

### 1. `is_token_expired {token_data}` (line ~690)
Checks if a token has expired by comparing `expires_at` field with current time.

**Returns:**
- `1` if expired
- `0` if valid
- `-1` if cannot determine (no expires_at field)

**Example:**
```tcl
set token_data [json::json2dict $token_json]
set expired [is_token_expired $token_data]
if {$expired == 1} {
    puts "Token has expired"
}
```

### 2. `refresh_access_token {token_data}` (line ~726)
Automatically refreshes an expired access token using the refresh_token.

**Process:**
1. Extracts `refresh_token` from token_data
2. Makes POST request to Microsoft OAuth endpoint
3. Receives new access_token and refresh_token
4. Saves updated token to token.json
5. Returns new token_data dict

**Returns:**
- New token_data dict on success
- Empty dict `{}` on failure

### 3. Enhanced `get_access_token_with_capability` (line ~807)
Now includes expiration checking and automatic refresh.

**New signature:**
```tcl
proc get_access_token_with_capability {rclone_remote {require_capability ""}}
```

**New parameter:**
- `require_capability`: Set to "full" to require full permissions (for write operations)

**New return format:**
- Returns 3 elements: `{access_token capability expires_at}`
- Previously returned 2 elements: `{access_token capability}`

**Workflow:**
```
token.json exists?
  ├─ Parse and check expiration
  ├─ Not expired? → return token
  ├─ Expired + has refresh_token?
  │   ├─ Try automatic refresh
  │   ├─ Success? → return new token
  │   └─ Failed? → fall through to rclone
  └─ Expired + no refresh_token? → fall through to rclone
  
Fallback to rclone.conf (read-only):
  ├─ If require_capability="full" → return error
  └─ Otherwise → return rclone token
```

## Enhanced Error Handling

### 1. Better 401 (Authentication) Errors
**In `make_http_request` (line ~1527):**
- Parses Microsoft's error response
- Detects "InvalidAuthenticationToken" errors
- Returns clear message: `"TOKEN_EXPIRED: <details>"`

**Example output:**
```
ERROR: HTTP 401 - Token expired or invalid
ERROR: {"error":{"code":"InvalidAuthenticationToken",...}}
```

### 2. CLI Write Operations Validation
**Updated functions:**
- `invite_user_cli` (line ~2445)
- `remove_user_permissions_cli` (line ~2256)

**New behavior:**
- Calls `get_access_token_with_capability $remote_name "full"`
- If only read-only token available → shows helpful error message
- Guides user to re-authenticate via GUI mode

**Example error output:**
```
❌ Operation requires full permissions (Files.ReadWrite.All + Sites.Manage.All)

This operation failed because:
  - token.json is expired or missing
  - rclone.conf token only has read-only permissions

To fix this:
  1. Run the script in GUI mode (wish acl-inspector.tcl)
  2. Trigger an operation requiring permissions (Invite or Remove)
  3. Complete browser authentication
  4. Try this command again

Alternatively, manually update token.json with a valid full-permission token.
```

### 3. Status Messages with Expiration Info
**In `fetch_acl` (line ~2714):**
Shows expiration timestamp in status messages:
```
✅ Using token (capability: full, expires: 2025-10-23T10:30:00Z)
```

Or during automatic refresh:
```
Token expired, refreshing...
✓ Token refreshed successfully (capability: full)
```

## Testing Scenarios

### Scenario 1: Expired token with valid refresh_token
**Setup:**
```bash
# Make token.json expired (change expires_at to past date)
sed -i 's/"expires_at".*/"expires_at" : "2025-10-22T00:00:00Z",/' token.json
```

**Expected behavior:**
1. Script detects expiration
2. Shows: "Token expired, refreshing..."
3. Automatically uses refresh_token to get new access_token
4. Saves updated token.json
5. Continues with operation
6. Shows: "✓ Token refreshed successfully (capability: full)"

**Test command:**
```bash
./acl-inspector.tcl "Test Folder" --debug
```

### Scenario 2: Expired token + expired refresh_token (read operation)
**Setup:**
- Expired token.json
- Expired refresh_token (refresh will fail)
- Valid rclone.conf token

**Expected behavior:**
1. Script detects expiration
2. Attempts refresh → fails
3. Shows: "Token refresh failed, falling back to rclone token..."
4. Falls back to rclone.conf
5. Operation continues in read-only mode

**Test command:**
```bash
./acl-inspector.tcl "Test Folder"
```

### Scenario 3: CLI write operation with expired token
**Setup:**
- Expired or missing token.json
- Valid rclone.conf token (read-only)

**Expected behavior:**
1. User runs: `--invite` or `--remove-user`
2. Script checks for "full" capability
3. Only rclone token available (read-only)
4. Shows detailed error message
5. Exits without attempting operation

**Test command:**
```bash
./acl-inspector.tcl "Test Folder" --invite user@example.com
```

### Scenario 4: Valid token (no regression)
**Setup:**
- Valid, non-expired token.json

**Expected behavior:**
- Works exactly as before
- No automatic refresh attempt
- Shows expiration info in status

**Test command:**
```bash
./acl-inspector.tcl "Test Folder"
```

### Scenario 5: GUI operation with expired token
**Setup:**
- Expired token.json
- User clicks "Invite" or "Remove" button in GUI

**Expected behavior:**
1. `ensure_edit_capability()` is called
2. Detects token needs refresh
3. Shows OAuth modal dialog
4. User can:
   - Authenticate via browser (gets new token)
   - Reload token.json (if updated externally)
5. Operation proceeds after successful auth

**Test:**
- Run in GUI mode: `wish acl-inspector.tcl`
- Browse to a folder
- Click "Invite User" button

## Backwards Compatibility

### Call Sites Updated
All locations calling `get_access_token_with_capability` have been updated to handle the new 3-element return format:
- Line ~1317: OAuth modal dialog
- Line ~1394: Token reload validation
- Line ~1700: Ensure edit capability
- Line ~1787: Invite user (GUI)
- Line ~1850: Remove permissions (GUI)
- Line ~2705: Fetch ACL (main entry point)

### Return Format
Old: `{access_token capability}`
New: `{access_token capability expires_at}`

Existing code that only uses first 2 elements continues to work:
```tcl
set result [get_access_token_with_capability $remote]
set token [lindex $result 0]   # Still works
set cap [lindex $result 1]     # Still works
# [lindex $result 2] is new expires_at field
```

## Configuration

No configuration changes required. The OAuth credentials are already defined in the script:
```tcl
set oauth(client_id) "..."
set oauth(client_secret) "..."
set oauth(token_url) "https://login.microsoftonline.com/common/oauth2/v2.0/token"
```

## Debugging

Enable debug mode to see detailed token handling:
```bash
./acl-inspector.tcl "Test Folder" --debug
```

Debug output includes:
- Token expiry timestamps
- Refresh attempt status
- Fallback decisions
- Capability detection

## Known Limitations

1. **Refresh token expiry**: If refresh_token has also expired, automatic refresh will fail. User must re-authenticate via GUI.

2. **No proactive refresh**: Tokens are only refreshed when detected as expired during use. Future enhancement could add proactive refresh (e.g., when token expires within 5 minutes).

3. **CLI limitations**: CLI mode cannot trigger browser authentication. For write operations, users must use GUI mode to obtain initial full-permission token.

## Files Modified

- `acl-inspector.tcl`: Main implementation (~150 lines added/modified)
- No other files changed

## Related Documentation

- See `IMPLEMENTATION-SUMMARY.md` for overall architecture
- See `README.md` for user-facing usage instructions

