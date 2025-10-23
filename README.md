# OneDrive ACL Manager (TCL Version)

A TCL/Tk-based tool for managing Access Control Lists (ACLs) in OneDrive using the Microsoft Graph API with OAuth tokens from rclone configuration.

## Features

- List permissions for OneDrive items
- Scan for folders and files with ACL permissions across your OneDrive
- Find items explicitly shared with specific users
- Remove user permissions (with dry-run mode)
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

The CLI uses a path-first interface where you specify the target path first, followed by options:

```bash
tclsh acl-inspector.tcl [PATH] [OPTIONS]
```

**PATH**: Item to inspect (default: `/` - root)

**Options:**
- `--only-user USER` - Filter to items USER has access to
- `--remove-user USER` - Remove USER's access (destructive)
- `--invite USER` - Invite USER with read/write access (inherited by children)
- `-r, --recursive` - Include children in scan
- `--max-depth N` - Max recursion depth (default: 3, requires `-r`)
- `--type TYPE` - Item types: `folders`, `files`, or `both` (default: `folders`)
- `--dry-run` - Preview changes without making them (with `--remove-user`)
- `--read-only` - Grant read-only access (with `--invite`, default: read/write)
- `--remote REMOTE` - OneDrive remote name (default: `OneDrive`)

### Examples

```bash
# GUI mode
wish acl-inspector.tcl "Documents"

# List ACL for a specific folder
tclsh acl-inspector.tcl "Documents/Project"

# Check if a user has access to a specific folder
tclsh acl-inspector.tcl "Work" --only-user bob@example.com

# Find all folders a user has access to (recursive, max depth 3)
tclsh acl-inspector.tcl --only-user admin@example.com -r

# Find user access in specific directory with custom depth
tclsh acl-inspector.tcl "Work" --only-user admin@example.com -r --max-depth 5

# Scan for both files and folders
tclsh acl-inspector.tcl "Projects" --only-user alice@example.com -r --type both

# Invite user to folder (permissions are inherited by children)
tclsh acl-inspector.tcl "Projects" --invite alice@example.com

# Invite user with read-only access
tclsh acl-inspector.tcl "Documents" --invite bob@example.com --read-only

# Remove user access (dry run first)
tclsh acl-inspector.tcl "Projects" --remove-user contractor@example.com -r --dry-run

# Remove user access for real (will prompt for confirmation)
tclsh acl-inspector.tcl "Projects" --remove-user contractor@example.com -r
```

## Permission Requirements

- **Read operations** (scanning, listing ACLs): Requires `Files.Read` (standard OneDrive token)
- **Write operations** (inviting users, removing permissions): Requires `Files.ReadWrite` + `Sites.Manage.All`

Note: The default rclone OneDrive token typically has read-only access. For write operations, you may need to reconfigure rclone with additional permissions.

## Key Features

### GUI Interface

- Interactive folder navigation
- Colour-coded permission display (green: owner, blue: write, yellow: read)
- Treeview showing permission details (ID, roles, users, links, expiration)

### CLI Scanning Optimization

Recursive scanning uses smart pruning for efficiency:
- Non-recursive by default (max-depth: 0) - checks only the specified path
- Use `-r` flag to enable recursion (default max-depth: 3)
- When explicit user permission is found, skips subfolders (inherited permissions)
- Shows progress tracking and folder counts per level
- Supports scanning both folders and files with `--type both`

**Safety Features:**
- `--dry-run` flag shows what would be removed without making changes
- Confirmation prompt before removing permissions (unless cancelled)
- Clear output showing affected items before and after operations

**Testing note**: Use `--max-depth 1` or `-r` for quick tests to avoid long scans.

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
