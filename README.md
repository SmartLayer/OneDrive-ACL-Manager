# OneDrive ACL Manager (TCL Version)

A TCL/Tk-based tool for auditing and managing Access Control Lists (ACLs) across OneDrive folder hierarchies using the Microsoft Graph API with OAuth tokens from rclone configuration.

## Primary Use Case

**Recursive ACL Auditing**: When management asks "Who has access to our Financial folder?", you need to scan not just the top-level folder, but all subfolders. A terminated employee might have been granted access to specific subfolders while lacking access to the parent - a common security oversight. This tool recursively scans entire folder hierarchies to ensure complete visibility of access permissions.

## Features

- **Recursive ACL scanning** - Audit complete folder hierarchies to find all access grants
- List permissions for OneDrive items at any depth
- Scan folders and files with smart pruning for inherited permissions
- Find items explicitly shared with specific users across folder trees
- Remove user permissions recursively with dry-run mode
- Invite users to folders with inherited permissions
- Dual interface: GUI (Tcl/Tk) and command-line
- Direct API access using rclone OAuth tokens

## Prerequisites

- Tcl/Tk 8.6+
- rclone installed and configured with OneDrive remote
- `tcllib` package (includes `json`)
- `tcl-tls` package for HTTPS requests

## Installation

1. **Install rclone and configure with OneDrive**:
   ```bash
   rclone config
   ```

2. **Install Tcl packages**:
   ```bash
   # Ubuntu/Debian:
   sudo apt-get install tcllib tcl-tls
   
   # macOS:
   brew install tcl-tk
   ```

## Usage

### GUI Mode

```bash
wish acl-inspector.tcl [item_path] [remote_name]
```

### Command Line Mode

The CLI uses a path-first interface for auditing access across folder hierarchies:

```bash
tclsh acl-inspector.tcl [PATH] [OPTIONS]
```

**PATH**: Folder or file to inspect (default: `/` - root)

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

### Examples

```bash
# ==================== RECURSIVE AUDITING (Primary Use Cases) ====================

# Audit who has access to Financial folder and ALL subfolders
tclsh acl-inspector.tcl "Finance" -r

# Deep audit with custom depth (e.g., for complex hierarchies)
tclsh acl-inspector.tcl "Projects" -r --max-depth 10

# Audit including both folders AND files
tclsh acl-inspector.tcl "Confidential" -r --type both

# Find everywhere an ex-employee still has access
tclsh acl-inspector.tcl "Company" --only-user exemployee@example.com -r

# ==================== SINGLE-ITEM OPERATIONS ====================

# Check ACL of one specific folder (no recursion)
tclsh acl-inspector.tcl "Finance/Budget2025"

# Check if specific user has access to one folder
tclsh acl-inspector.tcl "Finance/Budget2025" --only-user bob@example.com

# ==================== REMEDIATION OPERATIONS ====================

# Remove ex-employee from entire hierarchy (dry run first!)
tclsh acl-inspector.tcl "Projects" --remove-user exemployee@example.com -r --dry-run

# Actually remove after reviewing dry-run output
tclsh acl-inspector.tcl "Projects" --remove-user exemployee@example.com -r

# ==================== GRANTING ACCESS ====================

# Invite user to folder (automatically inherited by subfolders)
tclsh acl-inspector.tcl "Finance" --invite newaccountant@example.com

# Invite with read-only access
tclsh acl-inspector.tcl "Reports" --invite auditor@example.com --read-only

# ==================== GUI MODE ====================

# Launch GUI for interactive browsing
wish acl-inspector.tcl "Finance"
```

## Permission Requirements

- **Read operations** (scanning, listing ACLs): Requires `Files.Read` (standard OneDrive token)
- **Write operations** (inviting users, removing permissions): Requires `Files.ReadWrite` + `Sites.Manage.All`

Note: The default rclone OneDrive token typically has read-only access. For write operations, you may need to reconfigure rclone with additional permissions.

## Key Features

### Recursive ACL Auditing (Primary Function)

The tool is designed for comprehensive access audits across folder hierarchies. Common scenarios:

- **Post-termination audits**: "Did we revoke all of Bob's access?" - Scan recursively to find any remaining grants in subfolders
- **Compliance reviews**: "Who can access our Financial data?" - Complete visibility including subfolder permissions  
- **Access consolidation**: "Let's audit the Projects folder before archiving" - Discover all users with any level of access

**Smart scanning with pruning**:
- Recursive by default when using `-r` (max-depth: 3, adjustable)
- Non-recursive mode available for single-folder checks (omit `-r`)
- Automatically skips subfolders when explicit permission is found (inherited access is assumed)
- Progress tracking shows folders scanned per level
- Supports both folders and files with `--type both`

### GUI Interface

- Interactive folder navigation
- Colour-coded permission display (green: owner, blue: write, yellow: read)
- Treeview showing permission details (ID, roles, users, links, expiration)

### Safety Features

- `--dry-run` shows exactly what would be changed before execution
- Confirmation prompts required for all destructive operations
- Clear output listing all affected items
- Cannot remove owner permissions (enforced)

## Troubleshooting

**Token expired:**
```bash
# Refresh token by running any rclone command
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

OAuth token is extracted from `~/.config/rclone/rclone.conf` and used directly in API requests.

## Security Notes

- OAuth token is read from rclone.conf (not stored by this script)
- Tokens expire and can be refreshed by running any rclone command
- The script can read ACL information and modify permissions; use with appropriate caution
- Permission removal operations require confirmation (cannot be bypassed)
- Always use `--dry-run` first when removing permissions

## License

This project is provided as-is for educational and demonstration purposes.
