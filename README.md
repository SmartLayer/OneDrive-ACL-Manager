# OneDrive ACL Manager (TCL Version)

## Does This Sound Familiar?

If you've shared your OneDrive folders with friends, family, or collaborators over the years and you've lost track of who has access to what...

If you've stopped working with someone and you're worried they might still have access to your personal files somewhere deep in your folder structure...

If you need to know "Who can see my tax documents?" or "Who has access to my family photos?" and you can't get a clear answer...

If you're trying to clean up your OneDrive and need to audit who can see what before sharing more files...

**You need this tool.**

## The Problem

OneDrive shows you permissions for each folder, but not what's in the subfolders below. Someone you shared a subfolder with years ago might still have access - and you won't know unless you check every folder manually.

## The Solution

**OneDrive ACL Manager** scans entire folder hierarchies in one go, showing you all permissions at every level. Finally answer: "Who has access to what?"

## Features

**Dual Interface - Choose Your Workflow:**

- **GUI Mode (Tcl/Tk)** - Interactive browsing for exploring folders and viewing permissions visually (subset of command-line functions)
- **Command-line Mode** - Full feature set including recursive operations for auditing entire hierarchies (e.g., locate all files accessible by a given user, remove permissions across folder trees)

**Core Capabilities:**

- Recursive ACL scanning - Audit complete folder hierarchies to find all access grants
- Find items explicitly shared with specific users across folder trees
- Remove user permissions recursively with dry-run mode
- Invite users to folders with inherited permissions
- Scan folders and files with smart pruning for inherited permissions
- Dual token system: Uses both rclone configuration and token.json for flexible authentication

## Installation: Windows

1. **Download acl-inspector.tcl** to your preferred location (e.g., user home directory)

2. **Ensure rclone.conf exists** at `%APPDATA%\rclone\rclone.conf`:
   - A working configuration file is required (not yet tested without one)
   - Installing rclone itself is optional; copying a working rclone.conf from another system is sufficient

3. **Install Magicsplat TCL/TK 9.0**:
   - Other versions have not been tested
   - Runtime environment will be installed at `%APPDATA%\Local\Apps\Tcl90`

4. **Run the application**:
   ```
   C:>"AppData\Local\Apps\Tcl90\bin\wish.exe" acl-inspector.tcl
   ```

Tested on Windows 11.


## Installation: Linux and OS X

1. **Install rclone and configure with OneDrive**:
   ```bash
   rclone config
   ```

2. **Install Tcl packages**:
   ```bash
   # Ubuntu/Debian:
   sudo apt-get install tcllib tcl-tls
   
   # OS X:
   brew install tcl-tk
   ```

## Usage

### GUI Mode

```bash
wish acl-inspector.tcl [item_path] [remote_name]
```

### Command Line Mode

The CLI uses standard option-first interface for auditing access across folder hierarchies:

```bash
tclsh acl-inspector.tcl [OPTIONS] [PATH]
```

**PATH**: Folder or file to inspect (default: `/` - root) - must come after all options

**Note**: Options accept both single dash (`-option`) and double dash (`--option`) syntax. Help output shows single dashes but both work.

**Core Options:**
- `-r, --recursive` - **Scan folder and all subfolders** (default max-depth: 3) - Use this for complete access audits
- `--max-depth N` - Control recursion depth (use with `-r`, or set explicitly for any depth)
- `--type TYPE` - Item types to scan: `folders`, `files`, or `both` (default: `folders`)

**Filtering and Actions:**
- `--only-user USER` - Show only items USER has access to (works with or without `-r`)
- `--remove-user USER` - Remove USER's access from found items (destructive, requires `-r` or explicit depth)
- `--invite USER` - Invite USER with read/write access (inherited by children, cannot use with `-r`)

**Modifiers:**
- `--dry-run` - Preview changes without executing (with `--remove-user`)
- `--read-only` - Grant read-only instead of read/write (with `--invite`)
- `--debug` - Enable debug output
- `--remote REMOTE` - OneDrive remote name (default: `OneDrive`)
- `--help` - Display help message

### Examples

```bash
# ==================== RECURSIVE AUDITING (Primary Use Cases) ====================

# Audit who has access to Financial folder and ALL subfolders
tclsh acl-inspector.tcl -r "Finance"

# Deep audit with custom depth (e.g., for complex hierarchies)
tclsh acl-inspector.tcl -r --max-depth 10 "Projects"

# Audit including both folders AND files
tclsh acl-inspector.tcl -r --type both "Confidential"

# Find everywhere an ex-employee still has access
tclsh acl-inspector.tcl --only-user exemployee@example.com -r "Company"

# ==================== SINGLE-ITEM OPERATIONS ====================

# Check ACL of one specific folder (no recursion)
tclsh acl-inspector.tcl "Finance/Budget2025"

# Check if specific user has access to one folder
tclsh acl-inspector.tcl --only-user bob@example.com "Finance/Budget2025"

# ==================== REMEDIATION OPERATIONS ====================

# Remove ex-employee from entire hierarchy (dry run first!)
tclsh acl-inspector.tcl --remove-user exemployee@example.com -r --dry-run "Projects"

# Actually remove after reviewing dry-run output
tclsh acl-inspector.tcl --remove-user exemployee@example.com -r "Projects"

# ==================== GRANTING ACCESS ====================

# Invite user to folder (automatically inherited by subfolders)
tclsh acl-inspector.tcl --invite newaccountant@example.com "Finance"

# Invite with read-only access
tclsh acl-inspector.tcl --invite auditor@example.com --read-only "Reports"

# ==================== GUI MODE ====================

# Launch GUI for interactive browsing
wish acl-inspector.tcl "Finance"
```

## Permission Requirements

- **Read operations** (scanning, listing ACLs): Requires `Files.Read` (standard OneDrive token)
- **Write operations** (inviting users, removing permissions): Requires `Files.ReadWrite` + `Sites.Manage.All`

**Token Sources:**

The application uses two token sources:

1. **rclone.conf**: Read-only tokens from your rclone configuration (typically `Files.Read` scope)
2. **token.json**: Full-permission tokens stored in the application directory (created automatically when needed)

For write operations, the application will automatically request web-based authentication to create or update `token.json` with the required permissions. The application prioritises `token.json` when available and falls back to rclone.conf for read-only operations.

**Safety Features:**

- `--dry-run` shows exactly what would be changed before execution
- Confirmation prompts required for all destructive operations
- Cannot remove owner permissions (enforced)

## Troubleshooting

**Token expired:**

The application automatically refreshes expired tokens when possible. If automatic refresh fails:

- For `token.json`: Run the script in GUI mode and perform any write operation to trigger web-based re-authentication
- For rclone.conf: Refresh by running any rclone command:
  ```bash
  rclone about OneDrive:
  ```

**Package errors:**
```bash
# Install missing packages
sudo apt-get install tcllib tcl-tls
```

**Access denied:**
- Verify the item path is correct
- Check that you have permission to view the ACL
- Ensure your rclone token has sufficient permissions

## API Details

Uses Microsoft Graph API endpoints:
- `GET /me/drive/root:/{item-path}` - Get item info
- `GET /me/drive/items/{item-id}/permissions` - Get permissions
- `GET /me/drive/items/{item-id}/children` - List folder contents
- `POST /me/drive/items/{item-id}/invite` - Invite users
- `DELETE /me/drive/items/{item-id}/permissions/{perm-id}` - Remove permissions

OAuth tokens are obtained from either `token.json` (full permissions) or the rclone configuration file (read-only fallback) and used directly in API requests. The rclone configuration path is platform-specific: Windows uses `%APPDATA%\rclone\rclone.conf`, while Unix-like systems use `~/.config/rclone/rclone.conf`.

## Security Notes

- OAuth tokens are read from rclone.conf and token.json
- The application automatically creates and updates `token.json` when higher permissions are needed (via web-based OAuth flow)
- Tokens expire and are automatically refreshed when possible
- The script can read ACL information and modify permissions; use with appropriate caution
- Permission removal operations require confirmation (cannot be bypassed)
- Always use `--dry-run` first when removing permissions

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
