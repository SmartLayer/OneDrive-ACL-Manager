# Token Authentication Implementation

## Design Philosophy

The token authentication system is designed around a dual-source approach that balances user convenience with permission flexibility. The core principle is to leverage existing rclone configuration when possible while providing seamless upgrade paths to higher permissions when needed.

## Dual-Token Architecture

### Rationale

The system uses two token sources to address different use cases:

1. **token.json** (Primary for write operations): Application-managed token file that can be created and updated automatically when higher permissions are required. This allows the application to request additional scopes without requiring users to manually reconfigure rclone.

2. **rclone.conf** (Fallback for read operations): Existing rclone configuration provides immediate usability without requiring users to authenticate separately. This enables the application to work "out of the box" for read-only operations.

### Design Decisions

**Why prioritise token.json over rclone.conf?**

The application prioritises `token.json` because it can contain full permissions required for write operations. Checking `token.json` first ensures that operations requiring elevated permissions will succeed if a suitable token exists, without unnecessarily falling back to read-only tokens.

**Why not always use token.json?**

Not all users need write capabilities. For read-only auditing operations, using rclone.conf tokens avoids unnecessary authentication flows and respects the user's existing rclone setup. The fallback ensures the application remains functional even when `token.json` doesn't exist.

**Why different refresh behaviours?**

- **token.json refreshes are saved**: The application manages this file and needs to persist refreshed tokens to avoid repeated authentication. Users expect tokens to remain valid across sessions.

- **rclone.conf refreshes are in-memory only**: rclone manages its own configuration file. The application should not modify rclone's configuration to avoid conflicts with rclone's own token management. In-memory refresh provides temporary token validity without interfering with rclone's state.

## Token Retrieval Logic

### Priority Flow

The token retrieval follows a cascading priority system:

1. **Attempt token.json first** (if enabled):
   - If file exists and token is valid → use immediately
   - If expired but refresh_token available → refresh automatically and save
   - If expired and refresh fails → proceed to fallback
   - If file missing → proceed to fallback

2. **Fallback to rclone.conf**:
   - Parse token from rclone configuration
   - Refresh in-memory if expired (never save)
   - Use read-only capability
   - If write operations require full permissions → error with guidance

### Expiration Detection

The system handles two different expiration formats:

- **token.json**: Uses ISO 8601 `expires_at` timestamp (e.g., "2025-10-23T10:30:00Z")
- **rclone.conf**: Uses Unix timestamp `expiry` field

Both formats are detected and handled appropriately, allowing the system to work with tokens from different sources without format conversion requirements.

### Automatic Refresh Logic

Token refresh occurs when:

1. **Expiration detected**: Token's expiry time is compared against current time
2. **Refresh token available**: System checks for `refresh_token` field before attempting refresh
3. **Refresh succeeds**: New tokens are obtained from Microsoft OAuth endpoint
4. **Persistence decision**: Based on token source (save for token.json, discard for rclone.conf)

The refresh is attempted automatically, avoiding user interruption for operations that can proceed with refreshed tokens.

## Capability Detection

### Purpose

Not all tokens have the same permissions. The system needs to determine what operations a token can perform to:
- Avoid failed API calls that would waste time
- Provide clear error messages when operations require unavailable permissions
- Guide users to appropriate authentication paths

### Capability Levels

The system recognises three capability levels:

- **Full**: Contains `Files.ReadWrite.All` and `Sites.Manage.All` scopes, enabling all operations including inviting users and removing permissions
- **Read-only**: Contains only `Files.Read` scope, enabling read operations like listing ACLs and scanning folders
- **Unknown**: Scope information unavailable or cannot be determined

### Scope-Based Detection

Capability is determined by examining the token's `scope` field (if present). The system parses the space-separated scope list and checks for the presence of required scopes. This allows capability checking without making test API calls.

## Permission Requirements

### Operation-Based Requirements

Different operations require different permission levels:

- **Read operations** (listing ACLs, scanning folders): Only require `Files.Read`, which rclone tokens typically provide
- **Write operations** (inviting users, removing permissions): Require `Files.ReadWrite.All` + `Sites.Manage.All`, which typically require token.json

### Enforcing Requirements

When write operations are requested:
1. System checks if current token has required capability
2. If insufficient, provides clear error message explaining what's needed
3. Guides user to GUI mode where web-based authentication can obtain higher permissions
4. Refuses to attempt operation that would fail

This prevents unnecessary API calls and provides actionable guidance to users.

## GUI vs CLI Authentication

### GUI Mode Advantages

GUI mode can trigger browser-based OAuth flows because:
- Browser window can be opened automatically
- User can interact with Microsoft's authentication page
- OAuth callback can be captured via local HTTP server
- New tokens can be saved to token.json immediately

### CLI Mode Limitations

CLI mode cannot trigger browser authentication because:
- No graphical environment available
- Cannot open browser windows
- Cannot capture OAuth callbacks easily
- Must rely on existing tokens

### Design Consequence

Write operations in CLI mode require pre-existing `token.json` with full permissions. If unavailable, the system provides clear guidance to use GUI mode for initial authentication, after which CLI mode can use the saved token.

## Error Handling Strategy

### Graceful Degradation

The system is designed to fail gracefully:

1. **Try best option first**: Attempt token.json with full permissions
2. **Fallback to available option**: If token.json unavailable, use rclone.conf for read operations
3. **Clear error messages**: When operations cannot proceed, explain why and how to fix

### Error Message Design

Error messages follow this pattern:
- **What failed**: Operation that requires permissions
- **Why it failed**: Specific reason (missing token, expired token, insufficient permissions)
- **How to fix**: Step-by-step guidance, typically pointing to GUI mode for authentication

This approach ensures users understand the situation and know how to proceed, rather than encountering cryptic failures.

## Token Refresh Strategy

### Reactive vs Proactive

The current implementation uses **reactive refresh**: tokens are refreshed when detected as expired during use. This avoids unnecessary refresh attempts for tokens that may not be used.

**Trade-off**: If a token expires between application sessions, the first operation may encounter a delay while refresh occurs. A proactive approach (refreshing tokens that expire within a short window) could eliminate this delay but would require more frequent refresh checks.

### Refresh Token Expiry

When refresh tokens themselves expire, automatic refresh is no longer possible. The system detects this condition and guides users to re-authenticate via GUI mode, where a new refresh token can be obtained through browser-based OAuth.

## Security Considerations

### Token Storage

- **token.json**: Stored in application directory with restricted permissions (0600). Contains sensitive access and refresh tokens.
- **rclone.conf**: Managed by rclone, follows rclone's security practices. Application reads but never writes to this file.

### Token Lifecycle

Tokens have limited lifetimes (typically 1 hour for access tokens). The system handles expiration gracefully through automatic refresh, but users must re-authenticate when refresh tokens expire (typically 90 days for Microsoft tokens).

### Scope Limitation

The application requests only the minimum scopes needed:
- `Files.ReadWrite.All`: Required for modifying permissions
- `Sites.Manage.All`: Required for SharePoint/OneDrive site-level operations
- `User.Read`: Required for basic user information
- `offline_access`: Required to obtain refresh tokens

This follows the principle of least privilege, requesting only what's necessary for functionality.

## Limitations and Trade-offs

### Refresh Token Expiry

If refresh tokens expire, users must re-authenticate. This is a limitation of OAuth 2.0 refresh token lifetimes, not the application design. The system detects this condition and provides clear guidance.

### CLI Write Operations

CLI mode cannot obtain new tokens, requiring GUI mode for initial authentication. This is a necessary trade-off given CLI environment constraints. Once `token.json` exists, CLI mode can use it for subsequent operations.

### Format Differences

The system handles different token formats (ISO 8601 vs Unix timestamps) from different sources. This complexity is necessary to support both token sources without requiring format conversion or migration.

### No Proactive Refresh

Tokens are refreshed only when detected as expired, not proactively before expiration. This avoids unnecessary refresh operations but may cause slight delays on first use after token expiration.

## Debugging Support

The system provides debug logging that reveals:
- Which token source is being used
- Expiration status and timestamps
- Refresh attempts and outcomes
- Capability detection results
- Fallback decisions

This information helps diagnose authentication issues without exposing sensitive token values.

## Related Documentation

- See `IMPLEMENTATION-SUMMARY.md` for overall architecture
- See `README.md` for user-facing usage instructions
