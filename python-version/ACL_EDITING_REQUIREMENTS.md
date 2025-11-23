# OneDrive ACL Editing Feature Requirements

## Executive Summary

This document specifies requirements for implementing ACL (Access Control List) editing functionality in the OneDrive GUI application. The feature shall support token management, permission discovery, and interactive ACL modifications with automatic token acquisition and fallback mechanisms.

## 1. Token Management Architecture

### 1.1 Token Storage Hierarchy

The application shall implement a two-tier token storage system:

1. **Primary**: Local project directory token file (`token.json`)
   - Location: `./token.json` (same directory as the application)
   - Priority: Check this file first
   - Usage: Short-lived tokens with ACL editing permissions
   - Lifespan: Typically less than 24 hours (Microsoft sensitive permission tokens)

2. **Fallback**: rclone configuration token
   - Location: `~/.config/rclone/rclone.conf` (Linux/macOS) or `%APPDATA%\rclone\rclone.conf` (Windows)
   - Priority: Used when local token doesn't exist or is expired
   - Usage: Standard OneDrive read permissions
   - Lifespan: Longer-lived, auto-refreshed by rclone

### 1.2 Token File Format (`token.json`)

```json
{
  "access_token": "EwB4A8l6BAAURSN/FHlDW5xN...",
  "token_type": "Bearer",
  "expires_at": "2025-10-23T10:30:00Z",
  "scope": "Files.ReadWrite Files.ReadWrite.All Sites.Manage.All",
  "refresh_token": "M.R3_BAY...",
  "drive_id": "5D1B2B3BE100F93B",
  "drive_type": "personal"
}
```

### 1.3 Token Validation Logic

```
Function: get_access_token()
  1. Check if token.json exists in project directory
  2. If exists:
     a. Parse JSON
     b. Check expires_at timestamp
     c. If NOT expired:
        - Return access_token
     d. If expired:
        - Log: "Local token expired, falling back to rclone.conf"
        - Proceed to step 3
  3. Read token from rclone.conf:
     a. Parse rclone.conf format
     b. Extract access_token from specified remote section
     c. Return access_token
  4. If no valid token found:
     - Return null/error
```

## 2. Permission Discovery & Capability Detection

### 2.1 Token Capability Testing

Before enabling ACL editing features, the application shall test if the current token has necessary permissions.

**Problem**: Simply reading permissions (`GET .../permissions`) returns 200 OK for both read-only and read-write tokens, so this doesn't tell us if we can edit ACLs.

**Solution**: Check the token's scope claim to determine capabilities.

#### Method 1: Check Scope in token.json (Recommended)

**Important**: rclone.conf does NOT store scope information. When you check rclone.conf, it only contains:
```json
{
  "access_token": "EwB4A8l6...",
  "token_type": "Bearer",
  "refresh_token": "M.C547_BL2...",
  "expiry": "2025-10-23T07:04:04.819296972+10:00",
  "expires_in": 3599
}
```

So Method 1 only works for `token.json` that we create ourselves.

When saving `token.json` after OAuth flow, **ensure you include the scope field**:

```json
{
  "access_token": "EwB4A8l6...",
  "token_type": "Bearer",
  "scope": "Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access",
  "expires_at": "2025-10-23T10:30:00Z",
  "refresh_token": "M.C547_BL2...",
  "drive_id": "5D1B2B3BE100F93B"
}
```

**Detection Logic**:
```python
def check_token_capability(token_data: Dict) -> str:
    """
    Check if token has ACL editing permissions.
    Returns: "full", "read-only", or "unknown"
    """
    scope = token_data.get('scope', '')
    
    # If no scope field, we can't determine from this method
    if not scope:
        return "unknown"
    
    # Required scopes for ACL editing
    # Must have BOTH: Files.ReadWrite (or Files.ReadWrite.All) AND Sites.Manage.All
    
    has_write = ('Files.ReadWrite.All' in scope or 'Files.ReadWrite' in scope)
    has_manage = 'Sites.Manage.All' in scope
    
    if has_write and has_manage:
        return "full"  # Can edit ACLs
    
    if 'Files.Read' in scope:
        return "read-only"  # Can only read
    
    return "unknown"
```

**Usage**:
```python
# For token.json (has scope field)
with open('token.json') as f:
    token_data = json.load(f)
capability = check_token_capability(token_data)  # Returns "full" or "read-only"

# For rclone.conf token (no scope field)
rclone_token = get_rclone_token()
capability = check_token_capability({'access_token': rclone_token})  # Returns "unknown"
# Must use Method 4 (heuristic) for rclone tokens
```

#### Method 2: Decode Access Token (JWT) - **NOT APPLICABLE**

**Update**: Microsoft OneDrive access tokens are **not standard JWTs**. They use Microsoft's proprietary token format that cannot be decoded with standard JWT libraries.

Testing shows that tokens from rclone.conf:
- Do not follow `header.payload.signature` JWT structure
- Cannot be base64-decoded to extract claims  
- Scope information is not embedded in the token itself

**Verdict**: This method does NOT work for Microsoft OneDrive tokens. Use Method 1 (for token.json) or Method 4 (heuristic) instead.

#### Method 3: Attempt Non-Destructive Test (Not Recommended)

**Why Not Recommended**: There's no truly non-destructive write operation for permissions. Any attempt to add/modify/remove permissions will actually change the ACL.

**Alternative Test Approach** (if you must):
1. Try to add a permission for the current user (yourself)
2. Immediately remove it
3. Check response codes

But this is problematic:
- Might send unwanted notifications
- Could fail for reasons other than permissions
- Creates audit log entries
- Not truly non-destructive

**Verdict**: Don't use this method. Check scope instead.

#### Method 4: Simple Heuristic - Token Source (Recommended for rclone.conf)

Since rclone.conf doesn't store scope and tokens can't be decoded, use a simple but effective heuristic:

**Logic**:
- If token comes from `token.json` → User explicitly acquired it for ACL editing → Assume "full" permissions
- If token comes from `rclone.conf` → Standard rclone OneDrive token → Assume "read-only" permissions

**Implementation**:
```python
def get_token_with_capability() -> Tuple[Optional[str], str]:
    """
    Get token and its capability level.
    Returns: (access_token, capability_level)
    """
    # Try token.json first
    if os.path.exists('./token.json'):
        with open('./token.json') as f:
            token_data = json.load(f)
        
        # Check if expired
        if not is_token_expired(token_data):
            # Check scope in saved data
            capability = check_token_capability(token_data)
            return token_data['access_token'], capability
    
    # Fallback to rclone.conf
    rclone_token = get_rclone_token()
    return rclone_token, "read-only"  # Assume read-only for rclone tokens
```

### 2.2 Required Permission Scopes

**For Read-Only ACL Operations** (Scanner mode):
- `Files.Read` - Standard OneDrive read access
- Can list permissions, view metadata
- Works with rclone.conf tokens

**For ACL Editing Operations** (Edit mode):
- `Files.ReadWrite` - Read/write file access
- `Files.ReadWrite.All` - Read/write all files user can access
- `Sites.Manage.All` - Manage SharePoint sites (required for permission modifications)
- Requires elevated token (token.json with write permissions)

### 2.3 Capability Detection Algorithm (Revised)

**Recommended Approach**: Use a combination of Method 1 and Method 4.

```
Function: detect_acl_capabilities(token_source, token_data)
  1. Determine token source:
     a. If from token.json:
        - Check if 'scope' field exists in token_data
        - If scope exists:
          * Parse scope string (space-separated)
          * Check for required scopes:
            - Must have: "Sites.Manage.All"
            - Must have: "Files.ReadWrite" OR "Files.ReadWrite.All"
          * If both present: return "full"
          * Otherwise: return "read-only"
        - If no scope field:
          * Assume "full" (user acquired token for editing)
          * return "full"
     
     b. If from rclone.conf:
        - Rclone tokens don't include scope information
        - Microsoft OneDrive tokens are not decodable JWTs
        - Assume "read-only" (standard rclone permission level)
        - return "read-only"
  
  2. Return capability: "full" or "read-only"
```

**Summary of Working Methods**:
- ✅ **Method 1**: Check scope field in token.json (works when scope is saved)
- ❌ **Method 2**: Decode JWT (doesn't work - OneDrive tokens aren't JWTs)
- ❌ **Method 3**: Test with API call (doesn't work - both token types can read ACLs)
- ✅ **Method 4**: Check token source (works as reliable heuristic)

**Important**: Don't rely on API call success/failure to determine capabilities, since both read-only and read-write tokens can successfully read ACL information.

## 3. User Interface Integration

### 3.1 Mode Toggle Based on Token Capabilities

**Scanner Mode (Read-Only)**:
- Default mode when using rclone.conf token
- Display: Show ACL information in treeview
- Features available:
  - View permissions (ID, roles, email, link type)
  - Export ACL information
  - Scan folders for shared items
- Features disabled:
  - Edit button (greyed out)
  - Remove permission buttons
  - Invite user buttons

**Edit Mode (Read-Write)**:
- Enabled when token.json exists with valid ACL permissions
- Display: Replace treeview with editable ACL manager
- Features available:
  - All Scanner Mode features
  - Remove individual permissions
  - Add/invite users
  - Strip explicit permissions
  - Bulk remove user

### 3.2 Edit Button Behaviour

**Visual State**:
- Greyed out: Token lacks ACL modification permissions
- Enabled: Token has ACL modification permissions
- Loading spinner: Token acquisition in progress

**Click Action**:
```
Function: on_edit_button_click()
  1. Check current token capability
  2. If capability == "full":
     - Switch to Edit Mode immediately
     - Replace treeview with ACL editor
  3. If capability == "read-only" or "invalid":
     - Show confirmation dialog:
       "ACL editing requires elevated permissions. 
        Launch browser for authentication?"
     - If user confirms:
       - Call: acquire_acl_token()
       - Wait for token acquisition
       - If successful:
         - Save to token.json
         - Switch to Edit Mode
       - If failed:
         - Show error message
         - Stay in Scanner Mode
```

### 3.3 ACL Editor UI Layout

When in Edit Mode, the treeview shall be replaced with:

**Permissions List** (Treeview format):
```
Columns: [✓] | Role | User/Email | Link Type | Inherited | Actions
Rows:
  [ ] | owner  | Owner Name (owner@email.com)  | -        | No  | [Cannot Remove]
  [✓] | write  | Editor (editor@email.com)     | invite   | No  | [Remove]
  [✓] | read   | Viewer (viewer@email.com)     | sharing  | No  | [Remove]
  [ ] | read   | Anyone with link              | link     | No  | [Remove]
```

**Action Buttons**:
- `[+ Invite User]` - Opens dialog to invite new user with email and permission level
- `[Remove Selected]` - Removes all checked permissions
- `[Strip Explicit]` - Removes all non-inherited, non-owner permissions
- `[Cancel]` - Exit Edit Mode, return to Scanner Mode
- `[Apply]` - Commit changes and refresh view

## 4. Interactive Token Acquisition

### 4.1 OAuth Flow Integration

The application shall replicate rclone's OAuth flow for token acquisition.

**Process Overview**:
1. User clicks "Edit" button
2. Application checks token capability
3. If insufficient, prompt for authentication
4. Launch system browser with OAuth URL
5. Start local HTTP server to receive OAuth callback
6. Exchange authorization code for access token
7. Save token to `token.json`

### 4.1.1 Microsoft OAuth client details (as used in experiments)

These values mirror rclone's built-in OneDrive client and were used by our experiment scripts (`oauth_experiment.py`, `show_token_format.py`, `test_rclone_auth.py`). They work with personal Microsoft accounts and the local callback server.

```
Client ID: b15665d9-eda6-4092-8539-0eec376afd59
Client Secret: qtyfaBBYA403=unZUP40~_#
Redirect URI: http://localhost:53682/
Auth URL: https://login.microsoftonline.com/common/oauth2/v2.0/authorize
Token URL: https://login.microsoftonline.com/common/oauth2/v2.0/token
```

### 4.2 rclone OAuth Flow Simulation

**Step 1: Drive Type Selection**

When acquiring token, always select option `1` (OneDrive Personal or Business):
```
Choose a number from below, or type in an existing value of type string.
Press Enter for the default (onedrive).
 1 / OneDrive Personal or Business
   \ (onedrive)
 2 / Root Sharepoint site
   \ (sharepoint)
[... other options ...]
```
→ Select: `1` (onedrive)

**Step 2: Drive ID Selection**

After OAuth authentication, select option `3` (OneDrive personal):
```
Option config_driveid.
Select drive you want to use
Choose a number from below, or type in your own value of type string.
Press Enter for the default (b!JWXrxPY9skOcN9NJn5_wYgrUSYnmNUdInuk3cWVERL7oVlzOKXKaSbu5Bazn4q6M).
 1 / AEEE102E-CFF8-4E2A-89C6-03841FF83500 (personal)
   \ (b!JWXrxPY9skOcN9NJn5_wYgrUSYnmNUdInuk3cWVERL7oVlzOKXKaSbu5Bazn4q6M)
 2 / ODCMetadataArchive (personal)
   \ (b!JWXrxPY9skOcN9NJn5_wYgrUSYnmNUdInuk3cWVERL43E4nUPNLoQaGCS7JbSe1L)
 3 / OneDrive (personal)
   \ (5D1B2B3BE100F93B)
 4 / Bundles_b896e2bb7ca3447691823a44c4ad6ad7 (personal)
   \ (5D1B2B3BE100F93B)
```
→ Select: `3` (OneDrive personal - main drive ID: `5D1B2B3BE100F93B`)

### 4.3 OAuth Parameters for ACL Permissions

**Authorization URL**:
```
https://login.microsoftonline.com/common/oauth2/v2.0/authorize
```

**Required Parameters**:
- `client_id`: Microsoft OneDrive API client ID
- `response_type`: `code`
- `redirect_uri`: `http://localhost:53682/` (rclone's default local callback)
- `scope`: Space-separated list of permissions
  - `Files.Read`
  - `Files.ReadWrite`
  - `Files.ReadWrite.All`
  - `Sites.Manage.All`
  - `offline_access` (to get refresh token)
- `response_mode`: `query`
- `prompt`: `select_account` (allow user to choose account)

Notes from experiments:

- Microsoft returns a `scope` string in the token response.

- rclone requests `Sites.Read.All` by default, but personal accounts typically do not receive it. For ACL editing we must request `Sites.Manage.All` explicitly; this may require admin consent for organisational tenants. Personal accounts may be limited to file scopes only.

**Token Exchange Endpoint**:
```
POST https://login.microsoftonline.com/common/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={authorization_code}
&client_id={client_id}
&client_secret={client_secret}
&redirect_uri=http://localhost:53682/
&scope={requested_scopes}
```

### 4.4 Local HTTP server for OAuth callback (Tcl reference)

The following Tcl snippet demonstrates a minimal local callback server and token exchange. It integrates cleanly with `acl-inspector.tcl`. Use as a reference implementation.

```tcl
package require http
package require tls
package require json

::http::register https 443 ::tls::socket

set ::oauth(auth_url)  "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
set ::oauth(token_url) "https://login.microsoftonline.com/common/oauth2/v2.0/token"
set ::oauth(client_id)     "b15665d9-eda6-4092-8539-0eec376afd59"
set ::oauth(client_secret) "qtyfaBBYA403=unZUP40~_#"
set ::oauth(redirect_uri)  "http://localhost:53682/"
set ::oauth(scope)  "Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access"

# Start local HTTP server to capture the authorization code
proc oauth_start_local_server {} {
  set ::serverSock [socket -server oauth_accept 53682]
  return $::serverSock
}

proc oauth_accept {chan addr port} {
  fconfigure $chan -blocking 1 -translation crlf
  set req [read $chan]

  # Extract ?code= from the request line
  set code ""
  if {[regexp {GET\s+/\?code=([^&\s]+)} $req -> code]} {
    set ::oauth(auth_code) $code

    set body "<html><body style=\"font-family:Arial\"><h1>Authentication successful</h1><p>You can close this window.</p></body></html>"
    puts $chan "HTTP/1.1 200 OK" 
    puts $chan "Content-Type: text/html; charset=utf-8"
    puts $chan "Content-Length: [string length $body]"
    puts $chan ""
    puts -nonewline $chan $body
  } else {
    puts $chan "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
  }
  flush $chan
  close $chan

  # Stop listening after first callback
  catch {close $::serverSock}
}

proc oauth_build_auth_url {} {
  set q [::http::formatQuery \
    client_id     $::oauth(client_id) \
    response_type code \
    redirect_uri  $::oauth(redirect_uri) \
    scope         $::oauth(scope) \
    response_mode query \
    prompt        select_account]
  return "$::oauth(auth_url)?$q"
}

proc oauth_exchange_token {code} {
  set headers [list Content-Type application/x-www-form-urlencoded]
  set form [::http::formatQuery \
    grant_type    authorization_code \
    code          $code \
    client_id     $::oauth(client_id) \
    client_secret $::oauth(client_secret) \
    redirect_uri  $::oauth(redirect_uri) \
    scope         $::oauth(scope)]

  set tok [::http::geturl $::oauth(token_url) -method POST -headers $headers -query $form]
  set ok  [expr {[::http::status $tok] eq "ok"}]
  set data [::http::data $tok]
  ::http::cleanup $tok
  if {!$ok} {return -code error "Token request failed"}

  # Parse JSON and return a dict
  return [::json::json2dict $data]
}

proc oauth_save_token_json {tokenDict} {
  # Ensure scope is preserved – this is critical for capability detection
  # Compute ISO 8601 UTC expiry timestamp from expires_in
  set now   [clock seconds]
  set delta [dict get $tokenDict expires_in]
  set exp   [expr {$now + $delta}]
  set expiresAt [clock format $exp -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]

  set outDict [dict create \
    access_token  [dict get $tokenDict access_token] \
    token_type    [dict get $tokenDict token_type] \
    scope         [dict get $tokenDict scope] \
    expires_at    $expiresAt \
    expires_in    [dict get $tokenDict expires_in] \
    refresh_token [dict get $tokenDict refresh_token] \
    drive_id      "5D1B2B3BE100F93B" \
    drive_type    "personal"]

  set fh [open "token.json" w 0600]
  puts $fh [::json::dict2json $outDict]
  close $fh
}
```

Integration outline:

1. Start the local server, then open `oauth_build_auth_url` in the default browser.

2. After the callback arrives, call `oauth_exchange_token $::oauth(auth_code)`.

3. Save the token using `oauth_save_token_json` ensuring `scope` is included.

**Server Lifecycle**:
1. Start before launching browser
2. Listen on `http://localhost:53682/`
3. Accept single connection (OAuth callback)
4. Extract authorization code
5. Send HTTP 200 response with success message
6. Close server
7. Exchange code for token

### 4.5 Token Storage After Acquisition

After successful OAuth flow:
```
Function: save_token_to_file(token_data)
  1. Calculate expiry timestamp (current_time + expires_in)
  2. Create JSON structure:
     {
       "access_token": token_data.access_token,
       "token_type": "Bearer",
       "expires_at": expiry_timestamp (ISO 8601 format),
       "scope": token_data.scope,
       "refresh_token": token_data.refresh_token,
       "drive_id": "5D1B2B3BE100F93B",
       "drive_type": "personal"
     }
  3. Write to ./token.json
  4. Set file permissions: 0600 (owner read/write only)
  5. Return success

#### Saved `token.json` example (scope included)

```json
{
  "access_token": "EwAoA8l6BAAURSN/FHlDW5xN9KA...",
  "token_type": "Bearer",
  "scope": "Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access",
  "expires_at": "2025-10-23T12:30:00Z",
  "expires_in": 3600,
  "refresh_token": "M.C547_BL2.0.U.-CrGZ6kp2GXdwpf5o...",
  "drive_id": "5D1B2B3BE100F93B",
  "drive_type": "personal"
}
```

### 4.6 End‑to‑end steps (sequential)

1. Build the authorisation URL with the client details above and scopes: `Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access`.

2. Start the local Tcl HTTP server on `http://localhost:53682/`.

3. Open the browser to the authorisation URL and sign in.

4. On redirect, extract the `code` from the callback URL.

5. Exchange the `code` at the token endpoint with `client_id`, `client_secret`, `redirect_uri`, and the same scope string.

6. Persist the returned JSON to `token.json`, ensuring the `scope` field is saved verbatim.

7. Validate capability from `scope`:

   - Contains `Sites.Manage.All` and (`Files.ReadWrite` or `Files.ReadWrite.All`) → full ACL editing enabled.

   - Otherwise → read‑only; fall back to rclone token if present.

8. If `token.json` expires or is missing, load the rclone token and operate in scanner mode (read‑only).

## 15. Experiment artefacts and validated findings

The following scripts in this repository were used to validate behaviour and token formats:

- `oauth_experiment.py`: Full browser‑based flow with local server, exchanges code, and prints returned `scope`.

- `show_token_format.py`: Documents and prints the expected token response structure, including `scope` and an example `token.json` layout.

- `test_rclone_auth.py`: Invokes `rclone authorize onedrive` and demonstrates that the raw token response from Microsoft contains `scope`, but rclone’s saved token omits it.

Observed outcomes:

- Microsoft’s token response includes the `scope` field (v2 auth code flow).

- rclone tokens stored in `rclone.conf` do not preserve `scope`; treat them as read‑only for ACL editing purposes.

- Requesting `Sites.Manage.All` is necessary for ACL editing; it may require admin consent on organisational tenants.
```

## 5. Microsoft Graph API Operations for ACL Editing

### 5.1 Get Item ID from Path

**Purpose**: Convert OneDrive path to item ID for API operations.

**API Call**:
```http
GET https://graph.microsoft.com/v1.0/me/drive/root:/{item_path}
Authorization: Bearer {access_token}
```

**Example**:
```http
GET https://graph.microsoft.com/v1.0/me/drive/root:/Documents/Project
```

**Response** (200 OK):
```json
{
  "id": "01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K",
  "name": "Project",
  "folder": {
    "childCount": 15
  }
}
```

**Implementation**:
```python
def get_item_id(item_path: str, access_token: str) -> Optional[str]:
    headers = {"Authorization": f"Bearer {access_token}"}
    url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{item_path}"
    resp = requests.get(url, headers=headers, timeout=30)
    if resp.status_code == 200:
        return resp.json().get('id')
    return None
```

### 5.2 List Permissions for Item

**Purpose**: Get all permissions (ACL entries) for a specific item.

**API Call**:
```http
GET https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions
Authorization: Bearer {access_token}
```

**Response** (200 OK):
```json
{
  "value": [
    {
      "id": "aTowIy5mfG1lbWJlcnNoaXB8dXJuOmFpZDo3MzM0...",
      "roles": ["owner"],
      "grantedTo": {
        "user": {
          "displayName": "John Owner",
          "email": "owner@example.com",
          "id": "a1234567-89ab-cdef-0123-456789abcdef"
        }
      }
    },
    {
      "id": "aTowIy5mfG1lbWJlcnNoaXB8dXJuOmFpZDo5ODc2...",
      "roles": ["write"],
      "grantedTo": {
        "user": {
          "displayName": "Jane Editor",
          "email": "editor@example.com",
          "id": "b2345678-9abc-def0-1234-56789abcdef0"
        }
      },
      "inheritedFrom": null
    },
    {
      "id": "aTowIy5mfG1lbWJlcnNoaXB8dXJuOmFpZDoxMjM0...",
      "roles": ["read"],
      "link": {
        "type": "view",
        "scope": "organization",
        "webUrl": "https://onedrive.live.com/..."
      },
      "expirationDateTime": "2025-12-31T23:59:59Z"
    }
  ]
}
```

**Permission Object Structure**:
- `id`: Unique permission identifier (required for deletion)
- `roles`: Array of roles (`owner`, `write`, `read`)
- `grantedTo`: User who has permission (OneDrive Personal)
- `grantedToIdentities`: Array of users (OneDrive Business)
- `link`: Sharing link information (if applicable)
- `inheritedFrom`: Parent item if permission is inherited (null if explicit)
- `expirationDateTime`: When permission expires (optional)
- `hasPassword`: Boolean indicating password protection

### 5.3 Invite User (Add Permission)

**Purpose**: Grant permission to a user by sending invitation (OneDrive Personal).

**API Call**:
```http
POST https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/invite
Authorization: Bearer {access_token}
Content-Type: application/json

{
  "requireSignIn": true,
  "roles": ["write"],
  "recipients": [
    {
      "email": "newuser@example.com"
    }
  ],
  "message": "You have been granted editing access to this item."
}
```

**Permission Roles**:
- `owner`: Full control (usually cannot be assigned via API)
- `write`: Edit permission
- `read`: View-only permission

**Response** (200 OK):
```json
{
  "value": [
    {
      "id": "aTowIy5mfG1lbWJlcnNoaXB8...",
      "roles": ["write"],
      "grantedTo": {
        "user": {
          "displayName": "New User",
          "email": "newuser@example.com",
          "id": "c3456789-abcd-ef01-2345-6789abcdef01"
        }
      },
      "invitation": {
        "inviteUrl": "https://onedrive.live.com/..."
      }
    }
  ]
}
```

**Status Codes**:
- `200 OK`: Invitation sent successfully
- `201 Created`: Permission created directly (no invitation needed)
- `400 Bad Request`: Invalid email format
- `403 Forbidden`: Insufficient permissions to modify ACL
- `404 Not Found`: User not found in organisation

**Implementation**:
```python
def invite_user(item_id: str, email: str, role: str, access_token: str) -> bool:
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/invite"
    data = {
        "requireSignIn": True,
        "roles": [role],  # "write" or "read"
        "recipients": [{"email": email}],
        "message": f"You have been granted {role} access to this item."
    }
    resp = requests.post(url, headers=headers, json=data, timeout=30)
    return resp.status_code in [200, 201]
```

### 5.4 Remove Permission

**Purpose**: Delete a specific permission entry from an item's ACL.

**API Call**:
```http
DELETE https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions/{permission_id}
Authorization: Bearer {access_token}
```

**Response** (204 No Content): Permission successfully removed

**Status Codes**:
- `204 No Content`: Successfully removed
- `403 Forbidden`: Insufficient permissions or cannot remove owner
- `404 Not Found`: Permission ID not found (may already be removed)

**Implementation**:
```python
def remove_permission(item_id: str, permission_id: str, access_token: str) -> bool:
    headers = {"Authorization": f"Bearer {access_token}"}
    url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions/{permission_id}"
    resp = requests.delete(url, headers=headers, timeout=30)
    return resp.status_code == 204
```

### 5.5 Find Permission ID by Email

**Purpose**: Locate the permission ID for a specific user email address.

**Algorithm**:
```python
def find_user_permission_id(permissions: List[Dict], email: str) -> Optional[str]:
    """Find permission ID for a specific user email."""
    for perm in permissions:
        # Check grantedToIdentities (OneDrive Business)
        granted_to_identities = perm.get('grantedToIdentities', [])
        for identity in granted_to_identities:
            if identity.get('user') and identity['user'].get('email') == email:
                return perm.get('id')
        
        # Check grantedTo (OneDrive Personal)
        granted_to = perm.get('grantedTo')
        if granted_to and granted_to.get('user'):
            if granted_to['user'].get('email') == email:
                return perm.get('id')
    
    return None
```

**Usage**:
```python
# 1. Get all permissions
permissions = get_item_permissions(item_id, access_token)

# 2. Find specific user's permission
permission_id = find_user_permission_id(permissions, "user@example.com")

# 3. Remove the permission
if permission_id:
    remove_permission(item_id, permission_id, access_token)
```

### 5.6 Strip Explicit Permissions

**Purpose**: Remove all explicit (non-inherited, non-owner) permissions from an item.

**Algorithm**:
```python
def strip_explicit_permissions(item_id: str, access_token: str) -> int:
    """Remove all explicit permissions. Returns count of removed permissions."""
    # Get all permissions
    permissions = get_item_permissions(item_id, access_token)
    if not permissions:
        return 0
    
    removed_count = 0
    for perm in permissions:
        # Skip owner permissions (cannot be removed)
        if 'owner' in perm.get('roles', []):
            continue
        
        # Skip inherited permissions (not explicit)
        if perm.get('inheritedFrom'):
            continue
        
        # Remove this explicit permission
        permission_id = perm.get('id')
        if remove_permission(item_id, permission_id, access_token):
            removed_count += 1
    
    return removed_count
```

**Use Case**: Revert a folder to "private" (owner-only) or inherited-only permissions.

### 5.7 Bulk Remove User from Multiple Items

**Purpose**: Remove a specific user's access from multiple folders/files.

**Algorithm**:
```python
def bulk_remove_user(email: str, item_ids: List[str], access_token: str) -> Dict:
    """Remove user from multiple items. Returns success/failure counts."""
    results = {"success": 0, "failed": 0, "not_found": 0}
    
    for item_id in item_ids:
        # Get permissions for this item
        permissions = get_item_permissions(item_id, access_token)
        if not permissions:
            results["failed"] += 1
            continue
        
        # Find user's permission
        permission_id = find_user_permission_id(permissions, email)
        if not permission_id:
            results["not_found"] += 1
            continue
        
        # Remove the permission
        if remove_permission(item_id, permission_id, access_token):
            results["success"] += 1
        else:
            results["failed"] += 1
    
    return results
```

## 6. Error Handling & User Feedback

### 6.1 API Error Status Codes

**401 Unauthorized**:
- Meaning: Token expired or invalid
- Action: 
  - Display: "Token expired. Please acquire new token."
  - Automatically fallback to rclone.conf token
  - Switch to Scanner Mode (read-only)

**403 Forbidden**:
- Meaning: Token lacks necessary permissions
- Action:
  - Display: "Insufficient permissions for ACL editing."
  - Offer to acquire elevated token
  - Disable Edit Mode

**404 Not Found**:
- Meaning: Item or permission not found
- Action:
  - Display: "Item not found. Check path."
  - For permission removal: "Permission may already be removed."

**429 Too Many Requests**:
- Meaning: Rate limit exceeded
- Action:
  - Display: "Rate limit exceeded. Please wait."
  - Implement exponential backoff
  - Retry after specified delay

**500 Internal Server Error**:
- Meaning: Microsoft API issue
- Action:
  - Display: "Server error. Please try again later."
  - Log full error response for debugging

### 6.2 User Feedback Messages

**Token Status**:
- ✅ "Using local elevated token (expires: 2025-10-23 10:30)"
- ⚠️ "Local token expired, using rclone token (read-only)"
- ❌ "No valid token found. Please configure rclone."

**Permission Operations**:
- ✅ "Successfully invited user@example.com"
- ✅ "Removed permission for user@example.com"
- ✅ "Stripped 3 explicit permissions"
- ❌ "Failed to remove permission: Access denied"
- ℹ️ "No permission found for user@example.com"

**Mode Transitions**:
- "Switched to Edit Mode (ACL modification enabled)"
- "Switched to Scanner Mode (read-only)"
- "Acquiring elevated token... Please authenticate in browser."

## 7. Token Expiry & Automatic Fallback

### 7.1 Token Expiry Detection

**Proactive Check** (before API calls):
```python
def is_token_expired(token_data: Dict) -> bool:
    """Check if token is expired based on expires_at timestamp."""
    from datetime import datetime, timezone
    
    expires_at_str = token_data.get('expires_at')
    if not expires_at_str:
        return True  # No expiry info, assume expired
    
    expires_at = datetime.fromisoformat(expires_at_str)
    now = datetime.now(timezone.utc)
    
    # Add 5-minute buffer for safety
    buffer_minutes = 5
    return (expires_at - now).total_seconds() < (buffer_minutes * 60)
```

**Reactive Check** (after API call fails):
```python
def handle_api_response(response):
    """Handle API response and detect token expiry."""
    if response.status_code == 401:
        # Token expired or invalid
        delete_token_file()  # Remove expired token
        fallback_to_rclone_token()
        switch_to_scanner_mode()
    elif response.status_code == 403:
        # Token lacks permissions
        warn_insufficient_permissions()
```

### 7.2 Automatic Fallback Logic

```
Function: get_working_token()
  1. Try to load token.json
  2. If loaded:
     a. Check if expired (proactive)
     b. If expired:
        - Log: "Local token expired"
        - Delete token.json
        - Goto step 3
     c. If NOT expired:
        - Return token data
  3. Load token from rclone.conf
  4. Return rclone token data
  5. Update UI to reflect token source
```

### 7.3 Token Refresh (Optional Enhancement)

If refresh token is available in `token.json`:
```python
def refresh_access_token(refresh_token: str) -> Optional[Dict]:
    """Use refresh token to get new access token."""
    url = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    data = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": MICROSOFT_CLIENT_ID,
        "scope": "Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access"
    }
    resp = requests.post(url, data=data)
    if resp.status_code == 200:
        return resp.json()
    return None
```

**Benefits**:
- Avoid re-authentication for user
- Seamless token renewal
- Better user experience

## 8. Security Considerations

### 8.1 Token File Security

**File Permissions**:
- Linux/macOS: `chmod 600 token.json` (owner read/write only)
- Windows: Set ACL to restrict access to current user

**Token Scope Principle**:
- Request minimum necessary scopes
- Use elevated token only when needed
- Fall back to read-only token when editing complete

### 8.2 Token Storage Location

**Project Directory** vs **System Directory**:
- ✅ Project directory: Easy cleanup, project-specific tokens
- ❌ System directory: Harder to manage, potential conflicts

**Recommendation**: Store in project directory (`.`) with proper permissions.

### 8.3 Sensitive Data Handling

**Do NOT log**:
- Full access tokens (only show first/last 8 characters)
- Refresh tokens
- Authorization codes

**Example Safe Logging**:
```
✅ "Using token: EwB4A8l6...36K (expires: 2025-10-23)"
❌ "Using token: EwB4A8l6BAAURSN/FHlDW5xN..."
```

## 9. Implementation Roadmap

### Phase 1: Token Management (Foundation)
1. Implement token.json read/write functions
2. Implement rclone.conf fallback
3. Add token expiry detection
4. Test automatic fallback

### Phase 2: Permission Discovery
1. Implement token capability testing
2. Add permission scope checking
3. Create UI indicators for token type

### Phase 3: OAuth Integration
1. Implement local HTTP server for OAuth callback
2. Create browser launch function
3. Add authorization code exchange
4. Test full OAuth flow

### Phase 4: ACL Editor UI
1. Design ACL editor layout (replace treeview)
2. Implement permission list display
3. Add action buttons (invite, remove, strip)
4. Handle mode switching (scanner ↔ editor)

### Phase 5: ACL Operations
1. Implement invite user function
2. Implement remove permission function
3. Implement strip explicit permissions
4. Add bulk remove user function

### Phase 6: Polish & Error Handling
1. Add comprehensive error messages
2. Implement retry logic
3. Add progress indicators
4. Create user documentation

## 10. Testing Checklist

### Token Management Tests
- [ ] Load token from token.json (valid, non-expired)
- [ ] Detect expired token in token.json
- [ ] Fallback to rclone.conf when token.json missing
- [ ] Fallback to rclone.conf when token.json expired
- [ ] Handle missing rclone.conf gracefully

### OAuth Flow Tests
- [ ] Launch browser with correct OAuth URL
- [ ] Start local HTTP server successfully
- [ ] Receive OAuth callback
- [ ] Extract authorization code
- [ ] Exchange code for token
- [ ] Save token to token.json with correct format
- [ ] Handle user cancellation (browser closed)

### Permission Discovery Tests
- [ ] Detect read-only token (rclone.conf)
- [ ] Detect read-write token (token.json with ACL perms)
- [ ] Handle expired token during capability check
- [ ] Correctly enable/disable Edit button based on capability

### ACL Operation Tests
- [ ] List permissions for item
- [ ] Invite user with write permission
- [ ] Invite user with read permission
- [ ] Remove permission for specific user
- [ ] Strip explicit permissions
- [ ] Bulk remove user from multiple items
- [ ] Handle permission not found (already removed)
- [ ] Handle access denied (insufficient permissions)

### Error Handling Tests
- [ ] Handle 401 (token expired) → auto fallback
- [ ] Handle 403 (insufficient permissions) → disable edit mode
- [ ] Handle 404 (item not found) → show error message
- [ ] Handle 429 (rate limit) → implement backoff
- [ ] Handle network errors → show retry option

### UI Integration Tests
- [ ] Scanner Mode displays read-only ACL info
- [ ] Edit Mode shows editable ACL list
- [ ] Mode switching works correctly
- [ ] Edit button greyed out when token lacks permissions
- [ ] Edit button enabled when token has permissions
- [ ] Status messages displayed correctly

## 11. Reference Implementation Snippets

### 11.1 Complete Token Loading Function (Python)

```python
import json
import os
from datetime import datetime, timezone
from typing import Optional, Dict

def get_access_token(remote_name: str = "OneDrive") -> Optional[str]:
    """
    Get access token from token.json or fallback to rclone.conf.
    Returns access token string or None if not found.
    """
    # Try local token.json first
    token_file = "./token.json"
    if os.path.exists(token_file):
        try:
            with open(token_file, 'r') as f:
                token_data = json.load(f)
            
            # Check if expired
            expires_at_str = token_data.get('expires_at')
            if expires_at_str:
                expires_at = datetime.fromisoformat(expires_at_str)
                now = datetime.now(timezone.utc)
                
                if (expires_at - now).total_seconds() > 300:  # 5-minute buffer
                    print(f"✅ Using local token (expires: {expires_at_str})")
                    return token_data.get('access_token')
                else:
                    print("⚠️ Local token expired, falling back to rclone.conf")
                    os.remove(token_file)  # Clean up expired token
        except Exception as e:
            print(f"⚠️ Error reading token.json: {e}, falling back to rclone.conf")
    
    # Fallback to rclone.conf
    from .config_utils import get_access_token as get_rclone_token
    print("ℹ️ Using rclone.conf token (read-only mode)")
    return get_rclone_token(remote_name)
```

### 11.2 Permission Display with Inherited Flag

```python
def print_permission_details(perm: Dict) -> None:
    """Print detailed information about a single permission."""
    print(f"  ID: {perm.get('id', 'N/A')}")
    print(f"  Roles: {', '.join(perm.get('roles', []))}")
    
    # Check if inherited
    inherited = perm.get('inheritedFrom')
    if inherited:
        parent_id = inherited.get('id', 'N/A')
        print(f"  Inherited: Yes (from: {parent_id})")
    else:
        print(f"  Inherited: No (explicit)")
    
    # User information
    granted_to = perm.get('grantedTo')
    if granted_to and granted_to.get('user'):
        user = granted_to['user']
        print(f"  User: {user.get('displayName', 'N/A')}")
        print(f"  Email: {user.get('email', 'N/A')}")
    
    # Link information
    link = perm.get('link')
    if link:
        print(f"  Link Type: {link.get('type', 'N/A')}")
        print(f"  Link Scope: {link.get('scope', 'N/A')}")
    
    # Expiration
    if perm.get('expirationDateTime'):
        print(f"  Expires: {perm.get('expirationDateTime')}")
```

## 12. API Rate Limits & Best Practises

### 12.1 Microsoft Graph API Rate Limits

**Limits**:
- Personal OneDrive: ~1,000 requests per hour per user
- Business OneDrive: Higher limits, varies by tenant

**Best Practises**:
- Batch operations when possible
- Cache permission lists
- Implement exponential backoff on 429 errors
- Show progress indicators for bulk operations

### 12.2 Retry Logic with Exponential Backoff

```python
import time

def api_call_with_retry(func, max_retries=3):
    """Execute API call with exponential backoff on rate limit."""
    for attempt in range(max_retries):
        try:
            response = func()
            if response.status_code == 429:
                # Rate limited
                retry_after = int(response.headers.get('Retry-After', 60))
                print(f"⚠️ Rate limited. Waiting {retry_after} seconds...")
                time.sleep(retry_after)
                continue
            return response
        except Exception as e:
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt  # 1, 2, 4 seconds
                print(f"⚠️ Error: {e}. Retrying in {wait_time}s...")
                time.sleep(wait_time)
            else:
                raise
    return None
```

## 13. Glossary

- **ACL (Access Control List)**: List of permissions that specify who can access an item and what they can do
- **OAuth Token**: Temporary credential that grants access to Microsoft Graph API
- **Permission ID**: Unique identifier for a specific ACL entry
- **Inherited Permission**: Permission that comes from a parent folder
- **Explicit Permission**: Permission directly assigned to an item (not inherited)
- **Token Scope**: Set of permissions that a token has been granted
- **Drive ID**: Unique identifier for a OneDrive drive
- **Item ID**: Unique identifier for a file or folder in OneDrive

## 14. Appendix: Microsoft OAuth Client Configuration

For reference, when registering your application with Microsoft Azure AD (if creating custom client):

**Required API Permissions**:
- Microsoft Graph → Delegated Permissions:
  - `Files.Read` - Read user files
  - `Files.ReadWrite` - Read and write user files  
  - `Files.ReadWrite.All` - Read and write all files user can access
  - `Sites.Manage.All` - Manage SharePoint sites (required for ACL modifications)
  - `offline_access` - Maintain access to data (refresh token)

**Redirect URI**: `http://localhost:53682/` (for local OAuth callback)

**Account Type**: Personal Microsoft accounts and organisational accounts

---

**Document Version**: 1.0  
**Last Updated**: 2025-10-22  
**Author**: Generated from acl_manager.py analysis

