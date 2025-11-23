# OneDrive ACL Manager

This project provides comprehensive tools for managing Access Control Lists (ACLs) in OneDrive using the Microsoft Graph API with OAuth tokens from rclone configuration.

## Features

- **ACL Management**: List, invite, and remove permissions for OneDrive items
- **ACL Scanning**: Find all folders with ACL permissions across your OneDrive
- **Direct API Access**: Uses OAuth tokens from rclone.conf to access Microsoft Graph API directly
- **Cross-Platform**: Supports both OneDrive Personal and OneDrive Business accounts
- **Multiple Interfaces**: Python command-line tools and Tcl/Tk GUI

## Project Structure

```
OneDriveGuard/
├── src/                    # Python source code
│   ├── __init__.py        # Package initialisation
│   ├── acl_manager.py     # Main ACL management tool
│   ├── acl_scanner.py     # ACL scanning and discovery
│   ├── config_utils.py    # Shared configuration utilities
│   └── debug_permissions.py # Debug tools for permission analysis
└── README.md              # This file
```

## Prerequisites

- Python 3.6+
- rclone installed and configured with OneDrive remote
- `requests` library: `pip install requests`
- Valid OAuth token in `~/.config/rclone/rclone.conf`

## Permission Requirements

### ACL Scanner (Read-Only Operations)
The ACL scanner only requires **basic read permissions** and works with any standard OneDrive token:
- **Required permissions**: `Files.Read` (standard OneDrive read access)
- **Token type**: Regular OneDrive token (no special ACL permissions needed)
- **Operations**: List folders, read permissions, metadata access
- **Token refresh**: Same frequency as regular OneDrive operations

### ACL Manager (Read/Write Operations)
The ACL manager requires **elevated permissions** for modifying ACL settings:
- **Required permissions**: `Files.ReadWrite` + `Sites.Manage.All` (for ACL modifications)
- **Token type**: OneDrive token with ACL permissions
- **Setup command**: `rclone config update OneDrive-ACL --onedrive-metadata-permissions write`
- **Operations**: Create, modify, and delete permissions; send invitations
- **Token refresh**: May require more frequent refreshes due to elevated permissions

### Meta Command (Read-Only Operations)
The meta command works with **basic read permissions**:
- **Required permissions**: `Files.Read` (standard OneDrive read access)
- **Token type**: Regular OneDrive token (no special ACL permissions needed)
- **Operations**: Read item metadata, creation info, modification details
- **Token refresh**: Same frequency as regular OneDrive operations

**Recommendation**: Use the regular OneDrive token for scanning and metadata operations. Only use the ACL-specific token when you need to modify permissions.

## Installation

1. **Install rclone** (if not already installed):
   ```bash
   # Download and install rclone from https://rclone.org/downloads/
   ```

2. **Configure rclone with OneDrive**:
   ```bash
   rclone config
   # Follow the prompts to add a OneDrive remote
   ```

3. **Authenticate with OneDrive**:
   ```bash
   rclone authorize onedrive
   ```

4. **Install Python dependencies** (for Python version):
   ```bash
   pip install requests
   ```
## Usage

### ACL Manager (Python)

The main ACL management tool provides comprehensive permission control:

```bash
python -m src.acl_manager <command> [options]
```

**Commands:**
- `list <item_path> [remote_name]` - List ACL for the specified item
- `invite <email> <folder_path>... [remote_name]` - Send invitation with editing permission to multiple folders (Personal OneDrive)
- `remove <item_path> <email> [remote_name]` - Remove all permissions for the email
- `bulk-remove-user <email> [options] [remote_name]` - Find and remove user from all shared folders
- `strip <item_path> [remote_name]` - Remove all explicit (non-inherited) permissions from the item

**Examples:**
```bash
# List ACL for a folder
python -m src.acl_manager list "Documents"

# List ACL for a specific file
python -m src.acl_manager list "Documents/file.txt"

# Use a different remote name
python -m src.acl_manager list "Project Files" "MyOneDrive"

# Invite a user to multiple folders
python -m src.acl_manager invite amanuensis@weiwu.au "Documents/Project" "Documents/Shared"

# Remove user permissions from a specific folder
python -m src.acl_manager remove "Documents/Project" user@example.com "MyOneDrive"

# Find and remove user from ALL shared folders (with dry-run first)
python -m src.acl_manager bulk-remove-user expired-user@hotmail.com --dry-run
python -m src.acl_manager bulk-remove-user expired-user@hotmail.com

# Remove user only from folders under a specific directory
python -m src.acl_manager bulk-remove-user expired-user@hotmail.com --target-dir "Work"

# Strip all explicit permissions from a folder (leave only inherited/owner)
python -m src.acl_manager strip "Documents/Project"
```

### ACL Scanner (Python)

Scan your OneDrive for folders with ACL permissions:

```bash
python -m src.acl_scanner [options] [dirname]
```

**Options:**
- `--remote REMOTE_NAME` - OneDrive remote name (default: OneDrive)
- `--max-depth N` - Maximum depth to scan (default: 3)
- `--only-user EMAIL` - Filter to show only folders with explicit permissions for specific user (enables pruning optimization)
- `dirname` - Optional: scan only under this directory path

**Examples:**
```bash
# Scan all folders for ACL permissions
python -m src.acl_scanner

# Scan specific directory
python -m src.acl_scanner "Documents/Projects"

# Filter by user
python -m src.acl_scanner --only-user "user@example.com"

# Combine filters
python -m src.acl_scanner --only-user "user@example.com" "Work"

# Scan with custom depth
python -m src.acl_scanner --max-depth 5

# Use different remote
python -m src.acl_scanner --remote "MyOneDrive"
```

## Pruning Optimization

When using the `--only-user` parameter, the scanner implements smart pruning to dramatically improve performance:

- **Level-based scanning**: Scans folders level by level up to the specified `--max-depth` (default: 3)
- **Explicit permission detection**: Only includes folders where the user has explicit (non-inherited) permissions
- **Subtree pruning**: When a folder with explicit user permissions is found, all its subfolders are skipped (assumed to inherit permissions)
- **Progress tracking**: Shows folder counts per level as scanning progresses

**Example output:**
```
📊 Folder count by level:
   Level 0: 1 folders
   Level 1: 45 folders  
   Level 2: 203 folders
   Level 3: 891 folders

✅ Found explicit permission: 👥 Documents/Project
   🚀 Pruning: Found explicit permission, skipping subfolders (inherited)
```

This optimization is particularly effective for large OneDrive structures with many nested folders, as it avoids redundant API calls for inherited permissions.

## Output Information

Both versions display the following ACL information:

- **Permission ID**: Unique identifier for each permission
- **Roles**: Access level (owner, write, read)
- **User Information**: Display name and email address
- **Link Details**: Type and scope of sharing links
- **Expiration**: When the permission expires (if applicable)
- **Password Protection**: Whether the shared link requires a password

## Troubleshooting

### Common Issues

1. **"rclone config not found"**
   - Ensure rclone is installed and configured
   - Run `rclone config` to set up your OneDrive remote

2. **"No token found"**
   - Re-authenticate with OneDrive: `rclone authorize onedrive`
   - Check that the remote name matches your configuration

3. **"Token has expired"**
   Assuming the share is called OneDrive-ACL in rclone configuration:
   - The simplest fix: run any rclone command to automatically refresh the token:
     ```bash
     rclone about OneDrive-ACL:
     ```
   - Alternative: Refresh the token directly:
     ```bash
     rclone config reconnect OneDrive-ACL:
     ```
   - Or re-authenticate completely:
     ```bash
     rclone config
     # Select "Edit existing remote" → choose your OneDrive remote → follow prompts
     ```

4. **"Access denied"**
   - Verify you have permission to view the ACL for the specified item
   - Check that the item path is correct
   - Ensure your Microsoft Graph API permissions are sufficient

5. **"Network error"**
   - Check your internet connection
   - Verify firewall settings allow HTTPS connections to Microsoft Graph API

## API Details

The scripts use the Microsoft Graph API endpoints:

### Read-Only Operations (Scanner & Meta)
- **Get Item**: `GET /me/drive/root:/{item-path}` (requires `Files.Read`)
- **Get Permissions**: `GET /me/drive/items/{item-id}/permissions` (requires `Files.Read`)
- **Get Item Metadata**: `GET /me/drive/items/{item-id}?expand=createdBy,lastModifiedBy` (requires `Files.Read`)

### Read/Write Operations (Manager)
- **Create Permission**: `POST /me/drive/items/{item-id}/invite` (requires `Files.ReadWrite` + `Sites.Manage.All`)
- **Delete Permission**: `DELETE /me/drive/items/{item-id}/permissions/{permission-id}` (requires `Files.ReadWrite` + `Sites.Manage.All`)

### Permission Scopes Required
- **Basic operations**: `Files.Read` (included in standard OneDrive token)
- **ACL modifications**: `Files.ReadWrite` + `Sites.Manage.All` (requires `--onedrive-metadata-permissions write`)

The OAuth token is extracted from rclone's configuration file and used directly in API requests, bypassing the need for separate authentication.

## Security Notes

- The OAuth token is read from rclone.conf and used directly
- No credentials are stored by these scripts
- Tokens expire and can be refreshed by running any rclone command (e.g., `rclone about OneDrive-ACL:`)
- The scripts can read, create, and delete ACL information; use with appropriate caution

## License

This project is provided as-is for educational and demonstration purposes. 
