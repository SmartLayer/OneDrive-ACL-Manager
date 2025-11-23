#!/usr/bin/env python3
"""
OneDrive ACL Scanner - Find folders with ACL permissions using Graph API.

This script efficiently finds all folders in your OneDrive that have ACL permissions
by recursively traversing the entire folder structure and checking permissions for each folder.

Distinguished sharing types:
- 🔗 Folders shared via link
- 👥 Folders shared via direct permissions/invitations

Prerequisites:
- rclone must be installed and configured with OneDrive remote
- requests library (pip install requests)
- Valid OAuth token in ~/.config/rclone/rclone.conf

Usage:
    python -m src.acl_scanner [options] [dirname]
    
Options:
    --remote REMOTE_NAME    OneDrive remote name (default: OneDrive)
    --max-results N         Maximum results to return (default: 1000)
    --only-user EMAIL       Filter to show only folders shared with specific user
    dirname                 Optional: scan only under this directory path
    
Examples:
    python -m src.acl_scanner
    python -m src.acl_scanner "Documents/Projects"
    python -m src.acl_scanner --only-user "user@example.com"
    python -m src.acl_scanner --only-user "user@example.com" "Work"
    python -m src.acl_scanner --max-results 500
    python -m src.acl_scanner --remote "MyOneDrive"
"""

import requests
import json
import sys
import argparse
import os
from typing import Dict, List, Optional, Set, Tuple
from urllib.parse import quote
import time
from .config_utils import get_access_token





def analyze_permissions(permissions: List[Dict]) -> Tuple[bool, bool, int, List[str]]:
    """
    Analyze permissions to determine sharing type and get shared user list.
    Identifies owner by looking for "owner" role instead of requiring user ID.
    
    Returns:
        Tuple of (has_link_sharing, has_direct_sharing, permission_count, shared_users)
    """
    has_link_sharing = False
    has_direct_sharing = False
    shared_users = []
    
    for perm in permissions:
        # Skip owner permissions (identified by "owner" role)
        roles = perm.get('roles', [])
        if 'owner' in roles:
            continue
        
        # Check if this is a link permission
        link = perm.get('link')
        if link and link.get('type'):
            has_link_sharing = True
        
        # Check if this is a direct permission
        granted_to = perm.get('grantedTo')
        if granted_to and granted_to.get('user'):
            user = granted_to['user']
            has_direct_sharing = True
            email = user.get('email', user.get('displayName', 'Unknown'))
            if email not in shared_users:
                shared_users.append(email)
        
        # Check grantedToIdentities (OneDrive Business)
        granted_to_identities = perm.get('grantedToIdentities', [])
        for identity in granted_to_identities:
            if identity.get('user'):
                user = identity['user']
                has_direct_sharing = True
                email = user.get('email', user.get('displayName', 'Unknown'))
                if email not in shared_users:
                    shared_users.append(email)
    
    return has_link_sharing, has_direct_sharing, len(permissions), shared_users

def get_item_path(item_id: str, access_token: str) -> str:
    """Get the full path of an item using its parent chain."""
    headers = {"Authorization": f"Bearer {access_token}"}
    path_parts = []
    current_id = item_id
    
    try:
        while current_id:
            url = f"https://graph.microsoft.com/v1.0/me/drive/items/{current_id}"
            resp = requests.get(url, headers=headers, timeout=30)
            
            if resp.status_code != 200:
                break
            
            item_data = resp.json()
            name = item_data.get('name', 'Unknown')
            path_parts.insert(0, name)
            
            parent_ref = item_data.get('parentReference')
            if not parent_ref or parent_ref.get('path') == '/drive/root:':
                break
            
            current_id = parent_ref.get('id')
            if not current_id:
                break
        
        # Remove 'root' from path if present
        if path_parts and path_parts[0].lower() == 'root':
            path_parts = path_parts[1:]
        
        return '/'.join(path_parts) if path_parts else 'Unknown'
    
    except Exception:
        return 'Unknown'

def scan_shared_folders_recursive(access_token: str, max_depth: int = 3, target_dir: Optional[str] = None, only_user: Optional[str] = None) -> List[Dict]:
    """
    Recursively scan OneDrive for all shared folders by traversing the folder structure up to max_depth.
    When only_user is specified, implements smart pruning: skips subfolders when explicit permissions are found.
    
    Args:
        access_token: OAuth access token for Graph API
        max_depth: Maximum depth to scan (default: 3)
        target_dir: Optional directory path to scan under (e.g., "Documents/Projects")
        only_user: Optional email to filter results by user (enables pruning optimization)
    """
    print(f"🔍 Scanning OneDrive for shared folders recursively (max depth: {max_depth})...")
    if only_user:
        print(f"🎯 Filtering for user: {only_user} (with pruning optimization)")
    
    headers = {"Authorization": f"Bearer {access_token}"}
    shared_folders = []
    checked_folders = set()  # Track checked folders to avoid duplicates
    folders_per_level = {}  # Track folder counts per level
    target_user_lower = only_user.lower() if only_user else None
    
    def check_folder_recursive(folder_id: str, folder_path: str = "", current_depth: int = 0):
        """Recursively check a folder and all its subfolders for sharing."""
        if current_depth >= max_depth or folder_id in checked_folders:
            return
        
        checked_folders.add(folder_id)
        
        # Track folder count per level
        if current_depth not in folders_per_level:
            folders_per_level[current_depth] = 0
        folders_per_level[current_depth] += 1
        
        try:
            # Get permissions for this folder
            permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
            perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
            
            if perm_resp.status_code == 200:
                permissions_data = perm_resp.json()
                permissions = permissions_data.get("value", [])
                
                # Analyze permissions
                has_link, has_direct, perm_count, shared_users = analyze_permissions(permissions)
                
                # Check for explicit user permissions if only_user is specified
                has_explicit_user_permission = False
                if target_user_lower:
                    for perm in permissions:
                        # Skip owner permissions
                        roles = perm.get('roles', [])
                        if 'owner' in roles:
                            continue
                        
                        # Check if this permission is inherited (has inheritedFrom property)
                        inherited_from = perm.get('inheritedFrom')
                        if inherited_from:
                            # This permission is inherited, skip it
                            continue
                        
                        # Check direct user permissions
                        granted_to = perm.get('grantedTo')
                        if granted_to and granted_to.get('user'):
                            user = granted_to['user']
                            user_email = user.get('email', '').lower()
                            if target_user_lower in user_email:
                                has_explicit_user_permission = True
                                break
                        
                        # Check grantedToIdentities (OneDrive Business)
                        granted_to_identities = perm.get('grantedToIdentities', [])
                        for identity in granted_to_identities:
                            if identity.get('user'):
                                user = identity['user']
                                user_email = user.get('email', '').lower()
                                if target_user_lower in user_email:
                                    has_explicit_user_permission = True
                                    break
                        
                        if has_explicit_user_permission:
                            break
                
                # Determine if this folder should be included in results
                should_include_folder = False
                if target_user_lower:
                    # When filtering by user, only include if explicit permission found
                    should_include_folder = has_explicit_user_permission
                else:
                    # When not filtering by user, include all shared folders
                    should_include_folder = has_link or has_direct
                
                if should_include_folder:
                    # Validate that shared_users is not empty
                    if not shared_users:
                        print(f"   ❌ ERROR: Folder '{folder_path or folder_id}' has sharing enabled but empty shared_users list!")
                        print(f"   This indicates a bug in the permission analysis logic.")
                    else:
                        # Get full path if not already provided
                        if not folder_path:
                            folder_path = get_item_path(folder_id, access_token)
                        
                        # Get folder name
                        folder_info_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}"
                        info_resp = requests.get(folder_info_url, headers=headers, timeout=30)
                        folder_name = "Unknown"
                        if info_resp.status_code == 200:
                            folder_data = info_resp.json()
                            folder_name = folder_data.get('name', 'Unknown')
                        
                        # Determine symbol and sharing type
                        if has_link:
                            symbol = "🔗"
                            share_type = "Link sharing"
                        else:
                            symbol = "👥"
                            share_type = "Direct permissions"
                        
                        # Get the folder ID by path to ensure consistency
                        consistent_folder_id = folder_id
                        if folder_path:
                            try:
                                path_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{folder_path}"
                                path_resp = requests.get(path_url, headers=headers, timeout=30)
                                if path_resp.status_code == 200:
                                    path_data = path_resp.json()
                                    consistent_folder_id = path_data.get('id', folder_id)
                            except Exception:
                                # Fall back to original folder_id if path lookup fails
                                consistent_folder_id = folder_id
                        
                        shared_folders.append({
                            'path': folder_path,
                            'name': folder_name,
                            'id': consistent_folder_id,
                            'symbol': symbol,
                            'share_type': share_type,
                            'has_link_sharing': has_link,
                            'has_direct_sharing': has_direct,
                            'permission_count': perm_count,
                            'shared_users': shared_users
                        })
                        
                        if target_user_lower and has_explicit_user_permission:
                            print(f"   ✅ Found explicit permission: {symbol} {folder_path}")
                        else:
                            print(f"   ✅ Found shared: {symbol} {folder_path}")
                
                # Implement pruning: if explicit user permission found, skip children
                if target_user_lower and has_explicit_user_permission:
                    print(f"   🚀 Pruning: Found explicit permission, skipping subfolders (inherited)")
                    return  # Skip scanning children
            
            # Get children of this folder and recursively check them
            children_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/children"
            children_resp = requests.get(children_url, headers=headers, timeout=30)
            
            if children_resp.status_code == 200:
                children_data = children_resp.json()
                children = children_data.get("value", [])
                
                for child in children:
                    if 'folder' in child:
                        child_id = child.get('id')
                        child_name = child.get('name', 'Unknown')
                        child_path = f"{folder_path}/{child_name}" if folder_path else child_name
                        
                        # Recursively check this child folder
                        check_folder_recursive(child_id, child_path, current_depth + 1)
        
        except Exception as e:
            # Skip folders we can't access
            pass
    
    # Start from target directory or root
    try:
        if target_dir:
            # Get the target directory by path
            target_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{target_dir}"
            resp = requests.get(target_url, headers=headers, timeout=30)
            
            if resp.status_code == 200:
                target_data = resp.json()
                target_id = target_data.get('id')
                
                print(f"📂 Starting recursive search from directory: {target_dir}")
                check_folder_recursive(target_id, target_dir, current_depth=0)
            else:
                print(f"⚠️  Target directory '{target_dir}' not found or not accessible")
                return shared_folders
        else:
            # Start from root
            root_url = "https://graph.microsoft.com/v1.0/me/drive/root"
            resp = requests.get(root_url, headers=headers, timeout=30)
            
            if resp.status_code == 200:
                root_data = resp.json()
                root_id = root_data.get('id')
                
                print(f"📂 Starting recursive search from root...")
                check_folder_recursive(root_id, "", current_depth=0)
            else:
                print(f"⚠️  Failed to get root: {resp.status_code}")
                return shared_folders
    
    except Exception as e:
        print(f"❌ Search error: {e}")
    
    # Print level statistics
    print(f"\n📊 Folder count by level:")
    for level in sorted(folders_per_level.keys()):
        count = folders_per_level[level]
        print(f"   Level {level}: {count} folders")
    
    print(f"\n✅ Scan complete. Found {len(shared_folders)} shared folders.")
    print(f"   Checked {len(checked_folders)} total folders recursively.")
    return shared_folders

def filter_folders_by_user(shared_folders: List[Dict], target_user: str, access_token: str) -> List[Dict]:
    """
    Filter shared folders to only include those explicitly shared with a specific user.
    Excludes folders that only inherit permissions from parent folders.
    
    Args:
        shared_folders: List of shared folder dictionaries
        target_user: Email address of the user to filter by
        access_token: OAuth access token for Graph API
    
    Returns:
        Filtered list of folders explicitly shared with the target user
    """
    filtered_folders = []
    target_user_lower = target_user.lower()
    headers = {"Authorization": f"Bearer {access_token}"}
    
    print(f"🔍 Checking explicit permissions for user: {target_user}")
    
    for folder in shared_folders:
        folder_id = folder.get('id')
        folder_path = folder.get('path', '')
        
        # Check if this folder has explicit permissions for the target user
        has_explicit_permission = False
        
        try:
            # Get permissions for this specific folder
            permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
            perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
            
            if perm_resp.status_code == 200:
                permissions_data = perm_resp.json()
                permissions = permissions_data.get("value", [])
                
                # Check each permission for the target user
                for perm in permissions:
                    # Skip owner permissions
                    roles = perm.get('roles', [])
                    if 'owner' in roles:
                        continue
                    
                    # Check if this permission is inherited (has inheritedFrom property)
                    inherited_from = perm.get('inheritedFrom')
                    if inherited_from:
                        # This permission is inherited, skip it
                        continue
                    
                    # Check direct user permissions
                    granted_to = perm.get('grantedTo')
                    if granted_to and granted_to.get('user'):
                        user = granted_to['user']
                        user_email = user.get('email', '').lower()
                        if target_user_lower in user_email:
                            has_explicit_permission = True
                            break
                    
                    # Check grantedToIdentities (OneDrive Business)
                    granted_to_identities = perm.get('grantedToIdentities', [])
                    for identity in granted_to_identities:
                        if identity.get('user'):
                            user = identity['user']
                            user_email = user.get('email', '').lower()
                            if target_user_lower in user_email:
                                has_explicit_permission = True
                                break
                    
                    if has_explicit_permission:
                        break
                
                # If no explicit permission found, this folder inherits from parent
                if has_explicit_permission:
                    filtered_folders.append(folder)
                    print(f"   ✅ Explicit permission: {folder_path}")
                else:
                    print(f"   ⏭️  Inherited permission: {folder_path}")
        
        except Exception as e:
            # Skip folders we can't access
            print(f"   ❌ Error checking permissions for {folder_path}: {e}")
            continue
    
    return filtered_folders

def scan_shared_folders(rclone_remote: Optional[str] = None, max_depth: int = 3, target_dir: Optional[str] = None, only_user: Optional[str] = None, json_output: bool = False) -> None:
    """
    Scan OneDrive for all shared folders by recursively traversing the folder structure up to max_depth.
    When only_user is specified, implements smart pruning to skip subfolders with inherited permissions.
    
    Args:
        rclone_remote: Name of the rclone remote
        max_depth: Maximum depth to scan (default: 3)
        target_dir: Optional directory path to scan under
        only_user: Optional email to filter results by user (enables pruning optimization)
        json_output: If True, output detailed JSON instead of formatted text
    """
    print(f"=== OneDrive Shared Folders Scanner ===")
    print(f"Remote: {rclone_remote}")
    print(f"Max depth: {max_depth}")
    if target_dir:
        print(f"Target directory: {target_dir}")
    if only_user:
        print(f"Filtering by user: {only_user}")
    if json_output:
        print(f"Output format: JSON")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Scan for shared folders
    start_time = time.time()
    shared_folders = scan_shared_folders_recursive(access_token, max_depth, target_dir, only_user)
    scan_time = time.time() - start_time
    
    print()
    print("=" * 80)
    
    # Display results
    if shared_folders:
        if json_output:
            # Output detailed JSON for debugging
            output_data = {
                "scan_info": {
                    "scan_time_seconds": round(scan_time, 1),
                    "total_folders_found": len(shared_folders),
                    "target_user": only_user,
                    "target_directory": target_dir
                },
                "folders": []
            }
            
            for folder in shared_folders:
                folder_data = {
                    "path": folder['path'],
                    "name": folder['name'],
                    "id": folder['id'],
                    "symbol": folder['symbol'],
                    "share_type": folder['share_type'],
                    "has_link_sharing": folder['has_link_sharing'],
                    "has_direct_sharing": folder['has_direct_sharing'],
                    "permission_count": folder['permission_count'],
                    "shared_users": folder['shared_users'],
                    "permissions": get_detailed_permissions(folder['id'], access_token)
                }
                output_data["folders"].append(folder_data)
            
            print(json.dumps(output_data, indent=2))
        else:
            print(f"📁 Found {len(shared_folders)} shared folder(s) in {scan_time:.1f} seconds:")
            print("=" * 80)
            
            for folder in shared_folders:
                print(f"{folder['symbol']} {folder['path']}")
                print(f"   └─ {folder['share_type']} ({folder['permission_count']} permission(s))")
                
                if folder['shared_users']:
                    users_str = ', '.join(folder['shared_users'][:3])
                    if len(folder['shared_users']) > 3:
                        users_str += f" and {len(folder['shared_users']) - 3} more"
                    print(f"   └─ Shared with: {users_str}")
                
                if folder['has_link_sharing'] and folder['has_direct_sharing']:
                    print(f"   └─ Has both link sharing and direct permissions")
                print()
    else:
        print(f"ℹ️  No shared folders found in {scan_time:.1f} seconds")
        if only_user:
            print(f"This could mean:")
            print(f"  - No folders are shared with {only_user}")
            print(f"  - The user email '{only_user}' doesn't match any shared users")
        else:
            print("This could mean:")
            print("  - You haven't shared any folders")
            print("  - All shared items are files (not folders)")
            print("  - Permission issues accessing some folders")
    
    print("\n=== Scan Complete ===")
    print("💡 Tip: This recursive scan efficiently checks all folders in your OneDrive!")

def get_detailed_permissions(folder_id: str, access_token: str) -> List[Dict]:
    """Get detailed permissions for a folder including explicit vs inherited status."""
    headers = {"Authorization": f"Bearer {access_token}"}
    detailed_permissions = []
    
    try:
        permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
        perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
        
        if perm_resp.status_code == 200:
            permissions_data = perm_resp.json()
            permissions = permissions_data.get("value", [])
            
            for perm in permissions:
                perm_detail = {
                    "roles": perm.get('roles', []),
                    "inherited_from": perm.get('inheritedFrom'),
                    "is_explicit": perm.get('inheritedFrom') is None,
                    "granted_to": perm.get('grantedTo'),
                    "granted_to_identities": perm.get('grantedToIdentities', []),
                    "link": perm.get('link')
                }
                detailed_permissions.append(perm_detail)
    
    except Exception as e:
        # Return error info instead of failing
        detailed_permissions.append({"error": str(e)})
    
    return detailed_permissions

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description="Scan OneDrive for shared folders")
    parser.add_argument("--remote", default=None, 
                       help="Name of the OneDrive remote (default: auto-detect)")
    parser.add_argument("--max-depth", type=int, default=3,
                       help="Maximum depth to scan (default: 3)")
    parser.add_argument("--only-user", 
                       help="Filter to show only folders with explicit permissions for specific user (enables pruning optimization)")
    parser.add_argument("--json-output", action="store_true",
                       help="Output results in JSON format for debugging")
    parser.add_argument("dirname", nargs="?", 
                       help="Optional: scan only under this directory path")
    
    args = parser.parse_args()
    
    print("OneDrive Shared Folders Scanner")
    print("=" * 50)
    
    # Show default max depth if not specified
    if args.max_depth == 3:
        print("Using max depth: 3")
    
    # Check if requests is available
    try:
        import requests
    except ImportError:
        print("❌ requests library not found")
        print("Please install it: pip install requests")
        return
    
    # Execute the scan
    scan_shared_folders(args.remote, args.max_depth, args.dirname, args.only_user, args.json_output)

if __name__ == "__main__":
    main()
