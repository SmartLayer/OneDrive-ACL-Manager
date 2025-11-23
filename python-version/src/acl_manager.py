#!/usr/bin/env python3
"""
OneDrive ACL Manager - Using rclone.conf token to access Microsoft Graph API directly.

This script provides comprehensive ACL (Access Control List) management for OneDrive items:
1. Read the OAuth token from rclone.conf
2. Use it to make direct Microsoft Graph API calls
3. List, invite, and remove ACL permissions for specific OneDrive items

Prerequisites:
- rclone must be installed and configured with OneDrive remote
- requests library (pip install requests)
- Valid OAuth token in ~/.config/rclone/rclone.conf

Usage:
    python -m src.acl_manager <command> [options]
    
Commands:
    list <item_path>... [remote_name]  - List ACL for the specified item(s)
    meta <item_path>... [remote_name]  - Show metadata (creation date, creator, size, etc.) for the specified item(s)
    invite <email> <folder_path>... [remote_name]  - Send invitation with editing permission to multiple folders (Personal OneDrive)
    remove <email> <item_path>... [remote_name] - Remove all permissions for the email from specified item(s)
    strip <item_path>... [remote_name] - Remove all explicit (non-inherited) permissions from the specified item(s)
    bulk-remove-user <email> [options] [remote_name] - Find and remove user from all shared folders
    
Examples:
    python -m src.acl_manager list "Documents" "Photos"
    python -m src.acl_manager meta "Documents/Project" "Documents/Archive"
    python -m src.acl_manager invite amanuensis@weiwu.au "Documents/Project" "Documents/Shared"
    python -m src.acl_manager remove amanuensis@weiwu.au "Documents/Project" "Documents/Archive"
    python -m src.acl_manager strip "Documents/Project" "Documents/Temp"
    python -m src.acl_manager bulk-remove-user marianascbastos@hotmail.com --dry-run
    python -m src.acl_manager bulk-remove-user marianascbastos@hotmail.com --target-dir "Work"
"""

import requests
import json
import sys
import argparse
import os
from typing import Dict, List, Optional
from .config_utils import get_access_token
from .acl_scanner import scan_shared_folders_recursive, filter_folders_by_user


def _handle_api_error(status_code: int, response_text: str, operation: str) -> None:
    """
    Handle Microsoft Graph API errors with helpful user guidance.
    
    Args:
        status_code: HTTP status code from the API response
        response_text: Raw response text from the API
        operation: Description of what operation failed (for user context)
    """
    print(f"❌ Failed to {operation}: {status_code}")
    
    if status_code == 401:
        print("\n🔑 Token expired or invalid")
        print("Refresh with: rclone config update OneDrive-ACL --onedrive-metadata-permissions write")
    elif status_code == 403:
        print("❌ Access denied - you may not have permission for this operation")
        print("This could be due to:")
        print("  - Insufficient permissions on the item")
        print("  - Item is in a shared folder you don't own")
        print("  - Microsoft Graph API permissions not granted")
    elif status_code == 404:
        print("❌ Item not found - check that the path is correct")
    else:
        print(f"Response: {response_text}")



def process_multiple_items(item_paths: List[str], access_token: str, processor_func, operation_name: str) -> Dict:
    """
    Generic function to process multiple OneDrive items with a given processor function.
    
    Args:
        item_paths: List of paths to process
        access_token: OAuth access token
        processor_func: Function that processes a single item (item_id, item_path, access_token) -> bool
        operation_name: Name of the operation for logging (e.g., "ACL listing", "metadata retrieval")
    
    Returns:
        Dict with success/failure counts and summary
    """
    successful_items = 0
    failed_items = 0
    
    for i, item_path in enumerate(item_paths, 1):
        print(f"\n{'='*80}")
        print(f"Processing item {i}/{len(item_paths)}: {item_path}")
        print(f"{'='*80}")
        
        # Get item ID
        item_id = get_item_id(item_path, access_token)
        if not item_id:
            print(f"❌ Skipping item {item_path} - could not get item ID")
            failed_items += 1
            continue
        
        # Process the item
        try:
            success = processor_func(item_id, item_path, access_token)
            if success:
                successful_items += 1
            else:
                failed_items += 1
        except Exception as e:
            print(f"❌ Error processing {item_path}: {e}")
            failed_items += 1
    
    # Print summary
    print(f"\n{'='*80}")
    print(f"=== {operation_name.title()} Summary ===")
    print(f"Total items processed: {len(item_paths)}")
    print(f"Successful: {successful_items}")
    print(f"Failed: {failed_items}")
    
    if successful_items > 0:
        print(f"✅ Successfully processed {successful_items} item(s)")
    if failed_items > 0:
        print(f"❌ Failed to process {failed_items} item(s)")
    
    return {
        'successful': successful_items,
        'failed': failed_items,
        'total': len(item_paths)
    }


def print_permission_details(perm: Dict) -> None:
    """Print detailed information about a single permission."""
    print(f"  ID: {perm.get('id', 'N/A')}")
    print(f"  Roles: {', '.join(perm.get('roles', []))}")
    
    # Check for grantedTo (OneDrive Personal)
    granted_to = perm.get('grantedTo')
    if granted_to and granted_to.get('user'):
        user = granted_to['user']
        print(f"  User: {user.get('displayName', 'N/A')} ({user.get('id', 'N/A')})")
        print(f"  Email: {user.get('email', 'N/A')}")
    
    # Check for grantedToIdentities (OneDrive Business)
    granted_to_identities = perm.get('grantedToIdentities', [])
    if granted_to_identities:
        for identity in granted_to_identities:
            if identity.get('user'):
                user = identity['user']
                print(f"  User: {user.get('displayName', 'N/A')} ({user.get('id', 'N/A')})")
                print(f"  Email: {user.get('email', 'N/A')}")
    
    # Check for link information
    link = perm.get('link')
    if link:
        print(f"  Link Type: {link.get('type', 'N/A')}")
        print(f"  Link Scope: {link.get('scope', 'N/A')}")
        print(f"  Link URL: {link.get('webUrl', 'N/A')}")
    
    # Additional permission details
    if perm.get('hasPassword'):
        print(f"  Password Protected: Yes")
    
    if perm.get('expirationDateTime'):
        print(f"  Expires: {perm.get('expirationDateTime')}")


def find_user_permission_id(permissions: List[Dict], email: str) -> Optional[str]:
    """Find the permission ID for a specific user email."""
    for perm in permissions:
        # Check grantedToIdentities (OneDrive Business)
        granted_to_identities = perm.get('grantedToIdentities', [])
        for identity in granted_to_identities:
            if identity.get('user') and identity['user'].get('email') == email:
                return perm.get('id')
        
        # Check grantedTo (OneDrive Personal)  
        granted_to = perm.get('grantedTo')
        if granted_to and granted_to.get('user') and granted_to['user'].get('email') == email:
            return perm.get('id')
    
    return None


def get_item_permissions(item_id: str, access_token: str) -> Optional[List[Dict]]:
    """Get permissions for an item. Returns None on error."""
    headers = {"Authorization": f"Bearer {access_token}"}
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
    
    try:
        resp = requests.get(permissions_url, headers=headers, timeout=30)
        if resp.status_code == 200:
            permissions_data = resp.json()
            return permissions_data.get("value", [])
        else:
            print(f"❌ Failed to get permissions: {resp.status_code}")
            if resp.status_code == 403:
                print("This could be due to insufficient permissions or API access issues")
            return None
    except requests.exceptions.RequestException as e:
        print(f"❌ Network error: {e}")
        return None


def _process_single_acl_listing(item_id: str, item_path: str, access_token: str) -> bool:
    """Process ACL listing for a single item. Returns True on success."""
    # Get permissions for this item
    headers = {"Authorization": f"Bearer {access_token}"}
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
    print(f"\nGetting ACL from: {permissions_url}")
    
    try:
        resp = requests.get(permissions_url, headers=headers, timeout=30)
        print(f"Response Status: {resp.status_code}")
        
        if resp.status_code == 200:
            permissions_data = resp.json()
            permissions = permissions_data.get("value", [])
            
            if permissions:
                print(f"\n✅ Found {len(permissions)} permission(s) in ACL:")
                print("=" * 60)
                
                for i, perm in enumerate(permissions, 1):
                    print(f"\nPermission {i}:")
                    print_permission_details(perm)
                    print("-" * 40)
            else:
                print("ℹ️  No permissions found for this item (empty ACL)")
            return True
        else:
            _handle_api_error(resp.status_code, resp.text, "get ACL")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Network error: {e}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return False


def _process_single_permission_removal(email: str):
    """Return a closure that processes permission removal for a single item."""
    def processor(item_id: str, item_path: str, access_token: str) -> bool:
        # Get permissions for this item
        permissions = get_item_permissions(item_id, access_token)
        if permissions is None:
            return False
        
        # Find permission for the specified email
        target_permission_id = find_user_permission_id(permissions, email)
        
        if not target_permission_id:
            print(f"❌ No permission found for email: {email}")
            return False
        
        print(f"✅ Found permission ID: {target_permission_id}")
        
        # Remove the permission
        headers = {"Authorization": f"Bearer {access_token}"}
        permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
        delete_url = f"{permissions_url}/{target_permission_id}"
        print(f"\nRemoving permission via: {delete_url}")
        
        try:
            resp = requests.delete(delete_url, headers=headers, timeout=30)
            print(f"Response Status: {resp.status_code}")
            
            if resp.status_code == 204:
                print("✅ Successfully removed all permissions!")
                return True
            elif resp.status_code == 403:
                print("❌ Access denied - you may not have permission to modify ACL for this item")
                return False
            elif resp.status_code == 404:
                print("❌ Permission not found - it may have already been removed")
                return False
            else:
                print(f"❌ Failed to remove permission: {resp.status_code}")
                print(f"Response: {resp.text}")
                return False
                
        except requests.exceptions.RequestException as e:
            print(f"❌ Network error: {e}")
            return False
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            return False
    
    return processor


def get_item_id(item_path: str, access_token: str) -> Optional[str]:
    """
    Get the item ID for a given path.
    
    Args:
        item_path: Path to the folder or file in OneDrive
        access_token: OAuth access token
        
    Returns:
        Item ID if successful, None otherwise
    """
    headers = {"Authorization": f"Bearer {access_token}"}
    url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{item_path}"
    
    try:
        resp = requests.get(url, headers=headers, timeout=30)
        if resp.status_code != 200:
            _handle_api_error(resp.status_code, resp.text, "get item info")
            return None
        
        item_data = resp.json()
        item_id = item_data.get('id')
        if not item_id:
            print("❌ No item ID found in response")
            return None
        
        item_name = item_data.get('name', 'Unknown')
        item_type = 'folder' if 'folder' in item_data else 'file'
        print(f"✅ Found {item_type}: {item_name} (ID: {item_id})")
        return item_id
        
    except requests.exceptions.RequestException as e:
        print(f"❌ Network error: {e}")
        return None
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return None

def _process_single_acl_listing(item_id: str, item_path: str, access_token: str) -> bool:
    """Process ACL listing for a single item. Returns True on success."""
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
    print(f"\nGetting ACL from: {permissions_url}")
    
    # Get permissions for this item
    permissions = get_item_permissions(item_id, access_token)
    if permissions is None:
        return False
    
    if permissions:
        print(f"\n✅ Found {len(permissions)} permission(s) in ACL:")
        print("=" * 60)
        
        for j, perm in enumerate(permissions, 1):
            print(f"\nPermission {j}:")
            print_permission_details(perm)
            print("-" * 40)
    else:
        print("ℹ️  No permissions found for this item (empty ACL)")
    
    return True


def list_item_acl(item_paths: List[str], rclone_remote: str = "OneDrive") -> None:
    """
    List ACL (Access Control List) for one or more OneDrive items.
    
    Args:
        item_paths: List of paths to folders or files in OneDrive
        rclone_remote: Name of the OneDrive remote in rclone.conf
    """
    print(f"=== OneDrive ACL Lister ===")
    print(f"Items: {', '.join(item_paths)}")
    print(f"Remote: {rclone_remote}")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Process all items using the shared helper
    process_multiple_items(item_paths, access_token, _process_single_acl_listing, "ACL listing")

def invite_permission_to_folders(email: str, folder_paths: List[str], rclone_remote: str = "OneDrive") -> None:
    """
    Send invitation with editing permission for a specific email address to multiple folders (Personal OneDrive).
    
    Args:
        email: Email address to send invitation to
        folder_paths: List of folder paths in OneDrive to grant access to
        rclone_remote: Name of the OneDrive remote in rclone.conf
    """
    print(f"=== OneDrive ACL Manager - Send Invitation to Multiple Folders (Personal OneDrive) ===")
    print(f"Email: {email}")
    print(f"Folders: {', '.join(folder_paths)}")
    print(f"Remote: {rclone_remote}")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Process each folder
    successful_invites = 0
    failed_invites = 0
    
    for i, folder_path in enumerate(folder_paths, 1):
        print(f"\n--- Processing folder {i}/{len(folder_paths)}: {folder_path} ---")
        
        # Get item ID
        item_id = get_item_id(folder_path, access_token)
        if not item_id:
            print(f"❌ Skipping folder {folder_path} - could not get item ID")
            failed_invites += 1
            continue
        
        # Send invitation (Personal OneDrive)
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        }
        
        # Send invitation via the invite endpoint (Personal OneDrive)
        invite_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/invite"
        print(f"Sending invitation via: {invite_url}")
        
        invite_data = {
            "requireSignIn": True,
            "roles": ["write"],
            "recipients": [
                {
                    "email": email
                }
            ],
            "message": "You have been granted editing access to this item."
        }
        
        try:
            resp = requests.post(invite_url, headers=headers, json=invite_data, timeout=30)
            print(f"Response Status: {resp.status_code}")
            
            if resp.status_code == 200:
                invite_response = resp.json()
                print("✅ Successfully sent invitation for editing permission!")
                
                # Show invitation details
                value = invite_response.get('value', [])
                if value:
                    for invite in value:
                        print(f"Invitation sent to: {invite.get('grantedTo', {}).get('user', {}).get('email', 'N/A')}")
                        print(f"Roles: {', '.join(invite.get('roles', []))}")
                        if invite.get('invitation'):
                            print(f"Invitation URL: {invite['invitation'].get('inviteUrl', 'N/A')}")
                successful_invites += 1
                
            elif resp.status_code == 201:
                permission = resp.json()
                print("✅ Successfully added editing permission!")
                print(f"Permission ID: {permission.get('id', 'N/A')}")
                print(f"Roles: {', '.join(permission.get('roles', []))}")
                
                # Show granted user info
                granted_to = permission.get('grantedTo')
                if granted_to and granted_to.get('user'):
                    user = granted_to['user']
                    print(f"Granted to: {user.get('displayName', 'N/A')} ({user.get('email', 'N/A')})")
                successful_invites += 1
                
            elif resp.status_code == 400:
                print("❌ Bad request - check the email address format")
                print(f"Response: {resp.text}")
                failed_invites += 1
                
            elif resp.status_code == 403:
                print("❌ Access denied - you may not have permission to modify ACL for this item")
                failed_invites += 1
                
            elif resp.status_code == 404:
                print("❌ User not found - the email address may not exist in your organisation")
                failed_invites += 1
                
            else:
                print(f"❌ Failed to add permission: {resp.status_code}")
                print(f"Response: {resp.text}")
                failed_invites += 1
                
        except requests.exceptions.RequestException as e:
            print(f"❌ Network error: {e}")
            failed_invites += 1
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            failed_invites += 1
    
    # Summary
    print(f"\n=== Invitation Summary ===")
    print(f"Total folders processed: {len(folder_paths)}")
    print(f"Successful invitations: {successful_invites}")
    print(f"Failed invitations: {failed_invites}")
    
    if successful_invites > 0:
        print(f"✅ Successfully invited {email} to {successful_invites} folder(s)")
    if failed_invites > 0:
        print(f"❌ Failed to invite {email} to {failed_invites} folder(s)")

def _process_single_permission_removal(email: str):
    """Create a processor function for removing permissions for a specific email."""
    def processor(item_id: str, item_path: str, access_token: str) -> bool:
        # Get all permissions to find the one for this email
        permissions = get_item_permissions(item_id, access_token)
        if permissions is None:
            return False
        
        # Find permission for the specified email
        target_permission_id = find_user_permission_id(permissions, email)
        if not target_permission_id:
            print(f"❌ No permission found for email: {email}")
            return False
        
        print(f"✅ Found permission ID: {target_permission_id}")
        
        # Remove the permission
        headers = {"Authorization": f"Bearer {access_token}"}
        permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
        delete_url = f"{permissions_url}/{target_permission_id}"
        print(f"\nRemoving permission via: {delete_url}")
        
        try:
            resp = requests.delete(delete_url, headers=headers, timeout=30)
            print(f"Response Status: {resp.status_code}")
            
            if resp.status_code == 204:
                print("✅ Successfully removed all permissions!")
                return True
            elif resp.status_code == 403:
                print("❌ Access denied - you may not have permission to modify ACL for this item")
                return False
            elif resp.status_code == 404:
                print("❌ Permission not found - it may have already been removed")
                return False
            else:
                print(f"❌ Failed to remove permission: {resp.status_code}")
                print(f"Response: {resp.text}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"❌ Network error: {e}")
            return False
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            return False
    
    return processor


def remove_permission(email: str, item_paths: List[str], rclone_remote: str = "OneDrive") -> None:
    """
    Remove all permissions for a specific email address from one or more items.
    
    Args:
        email: Email address to remove permissions for
        item_paths: List of paths to folders or files in OneDrive
        rclone_remote: Name of the OneDrive remote in rclone.conf
    """
    print(f"=== OneDrive ACL Manager - Remove Permission ===")
    print(f"Email: {email}")
    print(f"Items: {', '.join(item_paths)}")
    print(f"Remote: {rclone_remote}")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Process all items using the shared helper
    processor = _process_single_permission_removal(email)
    process_multiple_items(item_paths, access_token, processor, f"permission removal for {email}")

def bulk_remove_user_access(email: str, rclone_remote: str = "OneDrive", target_dir: Optional[str] = None, dry_run: bool = False) -> None:
    """
    Find all folders shared with a specific user and systematically remove their access.
    
    Args:
        email: Email address to remove access for
        rclone_remote: Name of the OneDrive remote in rclone.conf
        target_dir: Optional directory path to limit search scope
        dry_run: If True, only show what would be removed without actually removing
    """
    print(f"=== OneDrive Bulk User Access Removal ===")
    print(f"Target user: {email}")
    print(f"Remote: {rclone_remote}")
    if target_dir:
        print(f"Search scope: {target_dir}")
    if dry_run:
        print("🔍 DRY RUN MODE - No changes will be made")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Find all shared folders
    print("🔍 Scanning for shared folders...")
    shared_folders = scan_shared_folders_recursive(access_token, max_results=1000, target_dir=target_dir)
    
    if not shared_folders:
        print("ℹ️  No shared folders found")
        return
    
    # Filter to folders shared with the target user
    print(f"🔍 Finding folders shared with {email}...")
    user_folders = filter_folders_by_user(shared_folders, email, access_token)
    
    if not user_folders:
        print(f"ℹ️  No folders found shared with {email}")
        return
    
    print(f"\n📋 Found {len(user_folders)} folder(s) shared with {email}:")
    print("=" * 80)
    
    for i, folder in enumerate(user_folders, 1):
        print(f"{i}. {folder['symbol']} {folder['path']}")
        print(f"   └─ {folder['share_type']} ({folder['permission_count']} permission(s))")
    
    print()
    
    if dry_run:
        print("🔍 DRY RUN - The following folders would have permissions removed:")
        for folder in user_folders:
            print(f"   Would remove {email} from: {folder['path']}")
        print(f"\nTo actually remove permissions, run without --dry-run")
        return
    
    # Confirm before proceeding
    print(f"⚠️  About to remove {email} from {len(user_folders)} folder(s)")
    try:
        confirm = input("Continue? (y/N): ").strip().lower()
        if confirm not in ['y', 'yes']:
            print("❌ Operation cancelled")
            return
    except KeyboardInterrupt:
        print("\n❌ Operation cancelled")
        return
    
    # Remove permissions from each folder
    successful_removals = 0
    failed_removals = 0
    
    print(f"\n🗑️  Removing {email} from folders...")
    print("=" * 80)
    
    for i, folder in enumerate(user_folders, 1):
        print(f"\n--- Processing folder {i}/{len(user_folders)}: {folder['path']} ---")
        
        try:
            # Get permissions for this folder
            headers = {"Authorization": f"Bearer {access_token}"}
            permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder['id']}/permissions"
            
            resp = requests.get(permissions_url, headers=headers, timeout=30)
            if resp.status_code != 200:
                _handle_api_error(resp.status_code, resp.text, "get permissions")
                failed_removals += 1
                continue
            
            permissions_data = resp.json()
            permissions = permissions_data.get("value", [])
            
            # Find permission for the specified email
            target_permission_id = None
            for perm in permissions:
                # Check grantedToIdentities (OneDrive Business)
                granted_to_identities = perm.get('grantedToIdentities', [])
                for identity in granted_to_identities:
                    if identity.get('user') and identity['user'].get('email', '').lower() == email.lower():
                        target_permission_id = perm.get('id')
                        break
                
                # Check grantedTo (OneDrive Personal)
                if not target_permission_id:
                    granted_to = perm.get('grantedTo')
                    if granted_to and granted_to.get('user') and granted_to['user'].get('email', '').lower() == email.lower():
                        target_permission_id = perm.get('id')
                        break
            
            if not target_permission_id:
                print(f"❌ No permission found for {email} (may have been removed already)")
                failed_removals += 1
                continue
            
            # Remove the permission
            delete_url = f"{permissions_url}/{target_permission_id}"
            del_resp = requests.delete(delete_url, headers=headers, timeout=30)
            
            if del_resp.status_code == 204:
                print(f"✅ Successfully removed {email}")
                successful_removals += 1
            elif del_resp.status_code == 403:
                print(f"❌ Access denied - insufficient permissions")
                failed_removals += 1
            elif del_resp.status_code == 404:
                print(f"❌ Permission not found (may have been removed already)")
                failed_removals += 1
            else:
                print(f"❌ Failed to remove permission: {del_resp.status_code}")
                print(f"Response: {del_resp.text}")
                failed_removals += 1
                
        except Exception as e:
            print(f"❌ Error processing folder: {e}")
            failed_removals += 1
    
    # Summary
    print(f"\n=== Bulk Removal Summary ===")
    print(f"Total folders processed: {len(user_folders)}")
    print(f"Successful removals: {successful_removals}")
    print(f"Failed removals: {failed_removals}")
    
    if successful_removals > 0:
        print(f"✅ Successfully removed {email} from {successful_removals} folder(s)")
    if failed_removals > 0:
        print(f"❌ Failed to remove {email} from {failed_removals} folder(s)")

def _process_single_metadata(item_id: str, item_path: str, access_token: str) -> bool:
    """Process metadata retrieval for a single item. Returns True on success."""
    headers = {"Authorization": f"Bearer {access_token}"}
    # Use expand to get additional metadata including createdBy and lastModifiedBy
    metadata_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}?expand=createdBy,lastModifiedBy"
    print(f"\nGetting metadata from: {metadata_url}")
    
    try:
        resp = requests.get(metadata_url, headers=headers, timeout=30)
        print(f"Response Status: {resp.status_code}")
        
        if resp.status_code == 200:
            item_data = resp.json()
            
            print(f"\n✅ Item Metadata:")
            print("=" * 60)
            
            # Basic information
            print(f"📁 Name: {item_data.get('name', 'N/A')}")
            print(f"🆔 ID: {item_data.get('id', 'N/A')}")
            print(f"📂 Type: {'Folder' if 'folder' in item_data else 'File'}")
            
            # Size information
            size = item_data.get('size', 0)
            if size > 0:
                if size >= 1024 * 1024 * 1024:  # GB
                    size_str = f"{size / (1024 * 1024 * 1024):.2f} GB"
                elif size >= 1024 * 1024:  # MB
                    size_str = f"{size / (1024 * 1024):.2f} MB"
                elif size >= 1024:  # KB
                    size_str = f"{size / 1024:.2f} KB"
                else:
                    size_str = f"{size} bytes"
                print(f"📏 Size: {size_str}")
            else:
                print(f"📏 Size: {'N/A (folder)' if 'folder' in item_data else '0 bytes'}")
            
            # Dates
            created_datetime = item_data.get('createdDateTime')
            if created_datetime:
                from datetime import datetime
                try:
                    dt = datetime.fromisoformat(created_datetime.replace('Z', '+00:00'))
                    print(f"📅 Created: {dt.strftime('%Y-%m-%d %H:%M:%S UTC')}")
                except:
                    print(f"📅 Created: {created_datetime}")
            
            modified_datetime = item_data.get('lastModifiedDateTime')
            if modified_datetime:
                try:
                    dt = datetime.fromisoformat(modified_datetime.replace('Z', '+00:00'))
                    print(f"📝 Last Modified: {dt.strftime('%Y-%m-%d %H:%M:%S UTC')}")
                except:
                    print(f"📝 Last Modified: {modified_datetime}")
            
            # Creator information
            created_by = item_data.get('createdBy')
            if created_by:
                print(f"\n👤 Creator Information:")
                user = created_by.get('user', {})
                if user:
                    print(f"   Name: {user.get('displayName', 'N/A')}")
                    print(f"   Email: {user.get('email', 'N/A')}")
                    print(f"   ID: {user.get('id', 'N/A')}")
                
                app = created_by.get('application')
                if app:
                    print(f"   Created via: {app.get('displayName', 'N/A')}")
            
            # Last modifier information
            last_modified_by = item_data.get('lastModifiedBy')
            if last_modified_by:
                print(f"\n✏️  Last Modified By:")
                user = last_modified_by.get('user', {})
                if user:
                    print(f"   Name: {user.get('displayName', 'N/A')}")
                    print(f"   Email: {user.get('email', 'N/A')}")
                    print(f"   ID: {user.get('id', 'N/A')}")
                
                # Application that modified it (if available)
                app = last_modified_by.get('application')
                if app:
                    print(f"   Modified via: {app.get('displayName', 'N/A')}")
            
            # Web URL
            web_url = item_data.get('webUrl')
            if web_url:
                print(f"\n🔗 Web URL: {web_url}")
            
            # Parent reference
            parent_ref = item_data.get('parentReference')
            if parent_ref:
                print(f"\n📁 Parent Information:")
                print(f"   Parent ID: {parent_ref.get('id', 'N/A')}")
                parent_path = parent_ref.get('path', '')
                if parent_path:
                    clean_path = parent_path.replace('/drive/root:', '').strip('/')
                    print(f"   Parent Path: {clean_path if clean_path else 'Root'}")
            
            # File-specific metadata
            if 'file' in item_data:
                file_info = item_data['file']
                print(f"\n📄 File-Specific Information:")
                mime_type = file_info.get('mimeType')
                if mime_type:
                    print(f"   MIME Type: {mime_type}")
                
                hashes = file_info.get('hashes', {})
                if hashes:
                    print(f"   File Hashes:")
                    for hash_type, hash_value in hashes.items():
                        print(f"     {hash_type}: {hash_value}")
            
            # Folder-specific metadata
            if 'folder' in item_data:
                folder_info = item_data['folder']
                print(f"\n📂 Folder-Specific Information:")
                child_count = folder_info.get('childCount')
                if child_count is not None:
                    print(f"   Child Count: {child_count}")
            
            # Additional metadata
            etag = item_data.get('eTag')
            if etag:
                print(f"\n🏷️  ETag: {etag}")
            
            ctag = item_data.get('cTag')
            if ctag:
                print(f"🏷️  CTag: {ctag}")
            
            return True
                
        elif resp.status_code == 403:
            print("❌ Access denied - you may not have permission to view metadata for this item")
            return False
        elif resp.status_code == 404:
            print("❌ Item not found - check the path")
            return False
        else:
            print(f"❌ Failed to get metadata: {resp.status_code}")
            print(f"Response: {resp.text}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Network error: {e}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return False


def get_item_metadata(item_paths: List[str], rclone_remote: str = "OneDrive") -> None:
    """
    Get metadata information for one or more OneDrive items including creation date, creator, etc.
    
    Args:
        item_paths: List of paths to folders or files in OneDrive
        rclone_remote: Name of the OneDrive remote in rclone.conf
    """
    print(f"=== OneDrive Item Metadata ===")
    print(f"Items: {', '.join(item_paths)}")
    print(f"Remote: {rclone_remote}")
    print()
    
    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return
    
    print("✅ Successfully extracted access token from rclone.conf")
    
    # Process all items using the shared helper
    process_multiple_items(item_paths, access_token, _process_single_metadata, "metadata retrieval")

def _process_single_strip_permissions(item_id: str, item_path: str, access_token: str) -> bool:
    """Process stripping explicit permissions for a single item. Returns True on success."""
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{item_id}/permissions"
    print(f"\nGetting ACL from: {permissions_url}")

    # Get permissions for this item
    permissions = get_item_permissions(item_id, access_token)
    if permissions is None:
        return False

    to_remove = []
    for perm in permissions:
        # Skip owner permissions
        roles = perm.get('roles', [])
        if 'owner' in roles:
            continue
        # Skip inherited permissions
        if perm.get('inheritedFrom'):
            continue
        # Otherwise, this is explicit and should be removed
        to_remove.append(perm.get('id'))

    if not to_remove:
        print("ℹ️  No explicit permissions to remove (only inherited or owner permissions present)")
        return True

    print(f"Found {len(to_remove)} explicit permission(s) to remove.")
    headers = {"Authorization": f"Bearer {access_token}"}
    removed = 0
    
    for perm_id in to_remove:
        delete_url = f"{permissions_url}/{perm_id}"
        print(f"Removing permission ID: {perm_id} via {delete_url}")
        
        try:
            del_resp = requests.delete(delete_url, headers=headers, timeout=30)
            if del_resp.status_code == 204:
                print(f"✅ Removed permission ID: {perm_id}")
                removed += 1
            elif del_resp.status_code == 403:
                print(f"❌ Access denied when removing permission ID: {perm_id}")
            elif del_resp.status_code == 404:
                print(f"❌ Permission ID {perm_id} not found (may have already been removed)")
            else:
                print(f"❌ Failed to remove permission ID {perm_id}: {del_resp.status_code}")
                print(f"Response: {del_resp.text}")
        except requests.exceptions.RequestException as e:
            print(f"❌ Network error removing {perm_id}: {e}")

    success = removed > 0
    if success:
        print(f"\n✅ Successfully removed {removed} explicit permission(s) from this item")
    else:
        print(f"\n❌ Failed to remove any permissions from this item")
    
    # List remaining permissions
    remaining_perms = get_item_permissions(item_id, access_token)
    if remaining_perms is not None:
        print(f"Remaining permissions ({len(remaining_perms)}):")
        for j, perm in enumerate(remaining_perms, 1):
            print(f"  {j}. ID: {perm.get('id', 'N/A')}, Roles: {', '.join(perm.get('roles', []))}, Inherited: {'Yes' if perm.get('inheritedFrom') else 'No'}")
    else:
        print("Could not fetch remaining permissions")
    
    return success


def strip_explicit_permissions(item_paths: List[str], rclone_remote: str = "OneDrive") -> None:
    """
    Remove all explicit (non-inherited, non-owner) permissions from one or more OneDrive items.
    Leaves only inherited permissions (or none if no inherited ACL).
    
    Args:
        item_paths: List of paths to folders or files in OneDrive
        rclone_remote: Name of the OneDrive remote in rclone.conf
    """
    print(f"=== OneDrive ACL Manager - Strip Explicit Permissions ===")
    print(f"Items: {', '.join(item_paths)}")
    print(f"Remote: {rclone_remote}")
    print()

    # Get access token
    access_token = get_access_token(rclone_remote)
    if not access_token:
        return

    print("✅ Successfully extracted access token from rclone.conf")

    # Process all items using the shared helper
    process_multiple_items(item_paths, access_token, _process_single_strip_permissions, "permission stripping")

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description="Manage ACL for OneDrive items using rclone.conf token")
    subparsers = parser.add_subparsers(dest='command', help='Available commands')
    
    # List command
    list_parser = subparsers.add_parser('list', help='List ACL for the specified item(s)')
    list_parser.add_argument("item_paths", nargs="+", help="One or more paths to folders or files in OneDrive")
    list_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")
    
    # Invite command
    invite_parser = subparsers.add_parser('invite', help='Send invitation with editing permission to multiple folders (Personal OneDrive)')
    invite_parser.add_argument("email", help="Email address to send invitation to")
    invite_parser.add_argument("folder_paths", nargs="+", help="One or more folder paths in OneDrive to grant access to")
    invite_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")
    
    # Remove command
    remove_parser = subparsers.add_parser('remove', help='Remove all permissions for the email from specified item(s)')
    remove_parser.add_argument("email", help="Email address to remove permissions for")
    remove_parser.add_argument("item_paths", nargs="+", help="One or more paths to folders or files in OneDrive")
    remove_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")

    # Meta command
    meta_parser = subparsers.add_parser('meta', help='Show metadata information for the specified item(s) (creation date, creator, etc.)')
    meta_parser.add_argument("item_paths", nargs="+", help="One or more paths to folders or files in OneDrive")
    meta_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")
    
    # Strip command
    strip_parser = subparsers.add_parser('strip', help='Remove all explicit (non-inherited) permissions from the specified item(s)')
    strip_parser.add_argument("item_paths", nargs="+", help="One or more paths to folders or files in OneDrive")
    strip_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")
    
    # Bulk remove user command
    bulk_remove_parser = subparsers.add_parser('bulk-remove-user', help='Find and remove a user from all shared folders')
    bulk_remove_parser.add_argument("email", help="Email address to remove from all folders")
    bulk_remove_parser.add_argument("--target-dir", help="Optional: limit search to this directory")
    bulk_remove_parser.add_argument("--dry-run", action="store_true", help="Show what would be removed without making changes")
    bulk_remove_parser.add_argument("--remote", default=None, help="Name of the OneDrive remote (default: auto-detect)")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    print("OneDrive ACL Manager")
    print("=" * 50)
    
    # Check if requests is available
    try:
        import requests
    except ImportError:
        print("❌ requests library not found")
        print("Please install it: pip install requests")
        return
    
    # Execute the appropriate command
    if args.command == 'list':
        list_item_acl(args.item_paths, args.remote)
    elif args.command == 'invite':
        invite_permission_to_folders(args.email, args.folder_paths, args.remote)
    elif args.command == 'remove':
        remove_permission(args.email, args.item_paths, args.remote)
    elif args.command == 'meta':
        get_item_metadata(args.item_paths, args.remote)
    elif args.command == 'strip':
        strip_explicit_permissions(args.item_paths, args.remote)
    elif args.command == 'bulk-remove-user':
        bulk_remove_user_access(args.email, args.remote, args.target_dir, args.dry_run)
    
    print("\n=== ACL Management Complete ===")
    print("This demonstrates direct access to OneDrive ACL via Microsoft Graph API")
    print("using the OAuth token from rclone.conf.")

if __name__ == "__main__":
    main()
