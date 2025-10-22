# OneDrive ACL Manager (TCL Version)

A TCL/Tk-based tool for managing Access Control Lists (ACLs) in OneDrive using the Microsoft Graph API with OAuth tokens from rclone configuration.

## Features

- List permissions for OneDrive items
- Scan for folders with ACL permissions across your OneDrive
- Find folders explicitly shared with specific users
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

**List ACL for an item:**
```bash
tclsh acl-inspector.tcl acl [--remote REMOTE] [--dir PATH] <item_path>
```

**Find folders shared with a user:**
```bash
tclsh acl-inspector.tcl user [--remote REMOTE] [--dir PATH] [--max-depth N] <user_email>
```

### Examples

```bash
# GUI mode
wish acl-inspector.tcl "Documents"

# List ACL for a folder
tclsh acl-inspector.tcl acl "Documents/Project"

# Find folders shared with a user (use --max-depth 1 for testing)
tclsh acl-inspector.tcl user admin@example.com --max-depth 1

# Search within specific directory
tclsh acl-inspector.tcl user --dir "Work" admin@example.com
```

## Permission Requirements

- **Read operations** (scanning, listing): Requires `Files.Read` (standard OneDrive token)
- **Write operations** (modifying ACLs): Requires `Files.ReadWrite` + `Sites.Manage.All`

## Key Features

### GUI Interface

- Interactive folder navigation
- Colour-coded permission display (green: owner, blue: write, yellow: read)
- Treeview showing permission details (ID, roles, users, links, expiration)

### User Scanning Optimization

The `user` subcommand uses smart pruning for efficiency:
- Scans level by level up to `--max-depth` (default: 3)
- When explicit user permission is found, skips subfolders (inherited permissions)
- Shows progress tracking and folder counts per level

**Testing note**: Use `--max-depth 1` for quick tests to avoid long scans.

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

OAuth token is extracted from `~/.config/rclone/rclone.conf` and used directly in API requests.

## Security Notes

- OAuth token is read from rclone.conf (not stored by this script)
- Tokens expire and can be refreshed by running any rclone command
- The script can read ACL information; use with appropriate caution

## License

This project is provided as-is for educational and demonstration purposes.
