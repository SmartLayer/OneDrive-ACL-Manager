#!/usr/bin/env python3
"""
Debug script to test permission detection for a specific folder
"""

import requests
import json
import configparser
import os
from typing import Optional

def get_access_token(rclone_remote: str = "OneDrive") -> Optional[str]:
    """Extract access token from rclone.conf for the specified remote."""
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    if not os.path.exists(conf_path):
        print(f"Error: rclone config not found at {conf_path}")
        return None
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    if rclone_remote not in config:
        print(f"Error: Remote '{rclone_remote}' not found in {conf_path}")
        return None
    
    section = config[rclone_remote]
    token_json = section.get("token")
    if not token_json:
        print(f"Error: No token found for remote '{rclone_remote}' in {conf_path}")
        return None
    
    try:
        token = json.loads(token_json)
    except Exception as e:
        print(f"Error: Could not parse token JSON: {e}")
        return None
    
    access_token = token.get("access_token")
    if not access_token:
        print("Error: No access_token in token JSON")
        return None
    
    return access_token

def debug_folder_permissions(folder_path: str, target_user: str):
    """Debug permissions for a specific folder"""
    access_token = get_access_token()
    if not access_token:
        print("Failed to get access token")
        return
    
    headers = {"Authorization": f"Bearer {access_token}"}
    target_user_lower = target_user.lower()
    
    print(f"🔍 Debugging permissions for folder: {folder_path}")
    print(f"🔍 Looking for user: {target_user}")
    print()
    
    # Get the folder by path
    folder_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{folder_path}"
    resp = requests.get(folder_url, headers=headers, timeout=30)
    
    if resp.status_code != 200:
        print(f"❌ Failed to get folder: {resp.status_code}")
        print(resp.text)
        return
    
    folder_data = resp.json()
    folder_id = folder_data.get('id')
    folder_name = folder_data.get('name')
    
    print(f"✅ Found folder: {folder_name} (ID: {folder_id})")
    print()
    
    # Get permissions for this folder
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
    perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
    
    if perm_resp.status_code != 200:
        print(f"❌ Failed to get permissions: {perm_resp.status_code}")
        print(perm_resp.text)
        return
    
    permissions_data = perm_resp.json()
    permissions = permissions_data.get("value", [])
    
    print(f"📋 Found {len(permissions)} permission(s):")
    print()
    
    has_explicit_permission = False
    
    for i, perm in enumerate(permissions):
        print(f"Permission {i}:")
        print(f"  Roles: {perm.get('roles', [])}")
        print(f"  Inherited from: {perm.get('inheritedFrom', 'None (explicit)')}")
        
        # Check grantedTo
        granted_to = perm.get('grantedTo')
        if granted_to:
            print(f"  Granted to: {granted_to}")
            if granted_to.get('user'):
                user = granted_to['user']
                user_email = user.get('email', 'No email')
                print(f"  User email: {user_email}")
                if target_user_lower in user_email.lower():
                    print(f"  ✅ MATCH FOUND for {target_user}!")
                    if not perm.get('inheritedFrom'):
                        has_explicit_permission = True
                        print(f"  ✅ This is an EXPLICIT permission!")
                    else:
                        print(f"  ⏭️  This is an INHERITED permission")
        
        # Check grantedToIdentities
        granted_to_identities = perm.get('grantedToIdentities', [])
        if granted_to_identities:
            print(f"  Granted to identities: {granted_to_identities}")
            for identity in granted_to_identities:
                if identity.get('user'):
                    user = identity['user']
                    user_email = user.get('email', 'No email')
                    print(f"  Identity user email: {user_email}")
                    if target_user_lower in user_email.lower():
                        print(f"  ✅ MATCH FOUND for {target_user}!")
                        if not perm.get('inheritedFrom'):
                            has_explicit_permission = True
                            print(f"  ✅ This is an EXPLICIT permission!")
                        else:
                            print(f"  ⏭️  This is an INHERITED permission")
        
        print()
    
    print("=" * 50)
    if has_explicit_permission:
        print(f"✅ RESULT: Folder has EXPLICIT permissions for {target_user}")
    else:
        print(f"⏭️  RESULT: Folder only has INHERITED permissions for {target_user}")

def test_folder_id_mismatch():
    """Test if there's a folder ID mismatch issue"""
    access_token = get_access_token()
    if not access_token:
        print("Failed to get access token")
        return
    
    headers = {"Authorization": f"Bearer {access_token}"}
    folder_path = "🇦🇺 Colourful.land Pty Ltd (Business Name = Historic Rivermill)"
    
    print("🔍 Testing folder ID consistency...")
    print()
    
    # Method 1: Get by path (like in debug script)
    folder_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{folder_path}"
    resp = requests.get(folder_url, headers=headers, timeout=30)
    
    if resp.status_code != 200:
        print(f"❌ Failed to get folder by path: {resp.status_code}")
        return
    
    folder_data = resp.json()
    folder_id_by_path = folder_data.get('id')
    print(f"✅ Folder ID by path: {folder_id_by_path}")
    
    # Method 2: Get by ID (like in main script)
    folder_info_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id_by_path}"
    info_resp = requests.get(folder_info_url, headers=headers, timeout=30)
    
    if info_resp.status_code != 200:
        print(f"❌ Failed to get folder by ID: {info_resp.status_code}")
        return
    
    folder_info_data = info_resp.json()
    folder_id_by_id = folder_info_data.get('id')
    print(f"✅ Folder ID by ID: {folder_id_by_id}")
    
    print()
    if folder_id_by_path == folder_id_by_id:
        print("✅ Folder IDs match - no ID mismatch issue")
    else:
        print("❌ Folder IDs don't match - this could be the issue!")

def test_main_script_logic():
    """Test the exact logic used in the main script"""
    access_token = get_access_token()
    if not access_token:
        print("Failed to get access token")
        return
    
    headers = {"Authorization": f"Bearer {access_token}"}
    target_user = "amanuensis@weiwu.au"
    target_user_lower = target_user.lower()
    
    print("🔍 Testing main script logic...")
    print(f"🔍 Looking for user: {target_user}")
    print()
    
    # Simulate the folder data that would be in shared_folders list
    folder_path = "🇦🇺 Colourful.land Pty Ltd (Business Name = Historic Rivermill)"
    
    # Get folder ID like the main script does
    folder_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{folder_path}"
    resp = requests.get(folder_url, headers=headers, timeout=30)
    
    if resp.status_code != 200:
        print(f"❌ Failed to get folder: {resp.status_code}")
        return
    
    folder_data = resp.json()
    folder_id = folder_data.get('id')
    
    print(f"✅ Using folder ID: {folder_id}")
    print()
    
    # Now test the exact filtering logic
    has_explicit_permission = False
    
    try:
        # Get permissions for this specific folder
        permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
        perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
        
        if perm_resp.status_code == 200:
            permissions_data = perm_resp.json()
            permissions = permissions_data.get("value", [])
            
            print(f"📋 Found {len(permissions)} permission(s):")
            print()
            
            # Check each permission for the target user
            for i, perm in enumerate(permissions):
                print(f"Checking permission {i}:")
                
                # Skip owner permissions
                roles = perm.get('roles', [])
                if 'owner' in roles:
                    print(f"  ⏭️  Skipping owner permission")
                    continue
                
                # Check if this permission is inherited (has inheritedFrom property)
                inherited_from = perm.get('inheritedFrom')
                if inherited_from:
                    # This permission is inherited, skip it
                    print(f"  ⏭️  Skipping inherited permission from {inherited_from}")
                    continue
                
                # Check direct user permissions
                granted_to = perm.get('grantedTo')
                if granted_to and granted_to.get('user'):
                    user = granted_to['user']
                    user_email = user.get('email', '').lower()
                    print(f"  🔍 Checking user email: {user_email}")
                    if target_user_lower in user_email:
                        has_explicit_permission = True
                        print(f"  ✅ Found explicit permission for {target_user}!")
                        break
                
                # Check grantedToIdentities (OneDrive Business)
                granted_to_identities = perm.get('grantedToIdentities', [])
                for identity in granted_to_identities:
                    if identity.get('user'):
                        user = identity['user']
                        user_email = user.get('email', '').lower()
                        print(f"  🔍 Checking identity email: {user_email}")
                        if target_user_lower in user_email:
                            has_explicit_permission = True
                            print(f"  ✅ Found explicit permission for {target_user}!")
                            break
                
                if has_explicit_permission:
                    break
                print()
            
            print("=" * 50)
            if has_explicit_permission:
                print(f"✅ RESULT: Folder has EXPLICIT permissions for {target_user}")
            else:
                print(f"⏭️  RESULT: Folder only has INHERITED permissions for {target_user}")
    
    except Exception as e:
        print(f"❌ Error: {e}")

def test_initial_scan_discovery():
    """Test if the folder is being discovered during initial scan"""
    access_token = get_access_token()
    if not access_token:
        print("Failed to get access token")
        return
    
    headers = {"Authorization": f"Bearer {access_token}"}
    target_folder_path = "🇦🇺 Colourful.land Pty Ltd (Business Name = Historic Rivermill)"
    
    print("🔍 Testing if folder is discovered during initial scan...")
    print(f"🔍 Looking for folder: {target_folder_path}")
    print()
    
    # Get the folder by path first
    folder_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{target_folder_path}"
    resp = requests.get(folder_url, headers=headers, timeout=30)
    
    if resp.status_code != 200:
        print(f"❌ Failed to get folder by path: {resp.status_code}")
        return
    
    folder_data = resp.json()
    folder_id = folder_data.get('id')
    
    print(f"✅ Target folder ID: {folder_id}")
    print()
    
    # Now simulate the initial scan logic - check permissions for this folder
    permissions_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{folder_id}/permissions"
    perm_resp = requests.get(permissions_url, headers=headers, timeout=30)
    
    if perm_resp.status_code != 200:
        print(f"❌ Failed to get permissions: {perm_resp.status_code}")
        return
    
    permissions_data = perm_resp.json()
    permissions = permissions_data.get("value", [])
    
    print(f"📋 Found {len(permissions)} permission(s) during initial scan:")
    print()
    
    # Simulate the analyze_permissions function logic
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
    
    print(f"Has link sharing: {has_link_sharing}")
    print(f"Has direct sharing: {has_direct_sharing}")
    print(f"Shared users: {shared_users}")
    print()
    
    if has_link_sharing or has_direct_sharing:
        print("✅ RESULT: Folder WOULD be discovered during initial scan")
        print(f"   It would be stored with ID: {folder_id}")
        print(f"   And shared_users: {shared_users}")
    else:
        print("❌ RESULT: Folder would NOT be discovered during initial scan")

def test_recursive_vs_path_id_mismatch():
    """Test if folder IDs are different between recursive scan and path-based lookup"""
    access_token = get_access_token()
    if not access_token:
        print("Failed to get access token")
        return
    
    headers = {"Authorization": f"Bearer {access_token}"}
    target_folder_path = "📚 📖 Manuals and Family Office Handbook"
    
    print("🔍 Testing recursive vs path-based folder ID mismatch...")
    print(f"🔍 Looking for folder: {target_folder_path}")
    print()
    
    # Method 1: Get by path (like when scanning specific folder)
    folder_url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{target_folder_path}"
    resp = requests.get(folder_url, headers=headers, timeout=30)
    
    if resp.status_code != 200:
        print(f"❌ Failed to get folder by path: {resp.status_code}")
        return
    
    folder_data = resp.json()
    folder_id_by_path = folder_data.get('id')
    print(f"✅ Folder ID by path: {folder_id_by_path}")
    
    # Method 2: Simulate recursive scan - get root, then find this folder in children
    root_url = "https://graph.microsoft.com/v1.0/me/drive/root"
    root_resp = requests.get(root_url, headers=headers, timeout=30)
    
    if root_resp.status_code != 200:
        print(f"❌ Failed to get root: {root_resp.status_code}")
        return
    
    root_data = root_resp.json()
    root_id = root_data.get('id')
    print(f"✅ Root ID: {root_id}")
    
    # Get children of root
    children_url = f"https://graph.microsoft.com/v1.0/me/drive/items/{root_id}/children"
    children_resp = requests.get(children_url, headers=headers, timeout=30)
    
    if children_resp.status_code != 200:
        print(f"❌ Failed to get children: {children_resp.status_code}")
        return
    
    children_data = children_resp.json()
    children = children_data.get("value", [])
    
    print(f"📋 Found {len(children)} children in root:")
    for child in children:
        if 'folder' in child:
            child_name = child.get('name', 'Unknown')
            child_id = child.get('id')
            print(f"  📁 {child_name}: {child_id}")
            
            if child_name == target_folder_path:
                print(f"  ✅ Found target folder in children: {child_id}")
                if child_id == folder_id_by_path:
                    print("  ✅ IDs match!")
                else:
                    print(f"  ❌ IDs don't match! Path: {folder_id_by_path}, Children: {child_id}")
                    print("  🔍 This could be the source of the bug!")
                    return
    
    print("❌ Target folder not found in root children")

if __name__ == "__main__":
    print("=== Testing recursive vs path ID mismatch ===")
    test_recursive_vs_path_id_mismatch()
    
    print("\n" + "="*60 + "\n")
    
    print("=== Testing initial scan discovery ===")
    test_initial_scan_discovery()
    
    print("\n" + "="*60 + "\n")
    
    print("=== Testing main script logic ===")
    test_main_script_logic()
    
    print("\n" + "="*60 + "\n")
    
    print("=== Testing folder permissions ===")
    debug_folder_permissions("🇦🇺 Colourful.land Pty Ltd (Business Name = Historic Rivermill)", "amanuensis@weiwu.au")
    
    print("\n" + "="*60 + "\n")
    
    print("=== Testing folder ID consistency ===")
    test_folder_id_mismatch() 