#!/usr/bin/env python3
"""
Shared configuration utilities for OneDrive ACL management tools.

This module provides shared functions for:
- Reading rclone configuration
- Extracting access tokens
- Finding OneDrive remotes
- Prompting for configuration when needed
"""

import configparser
import json
import os
from datetime import datetime, timezone
from typing import Optional, List, Tuple

def find_onedrive_remotes() -> List[str]:
    """
    Find all OneDrive remotes in rclone configuration.
    
    Returns:
        List of OneDrive remote names
    """
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    if not os.path.exists(conf_path):
        return []
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    onedrive_remotes = []
    for section_name in config.sections():
        if section_name.startswith('[') and section_name.endswith(']'):
            # Skip section headers
            continue
        
        section = config[section_name]
        remote_type = section.get('type', '').lower()
        
        # Check for OneDrive types
        if remote_type in ['onedrive', 'onedrivebusiness', 'sharepoint']:
            onedrive_remotes.append(section_name)
    
    return onedrive_remotes

def get_access_token(rclone_remote: Optional[str] = None) -> Optional[str]:
    """
    Extract access token from rclone.conf for the specified remote.
    
    Args:
        rclone_remote: Name of the OneDrive remote in rclone.conf. 
                      If None, will prompt and find the first OneDrive entry.
        
    Returns:
        Access token string if successful, None otherwise
    """
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    if not os.path.exists(conf_path):
        print(f"Error: rclone config not found at {conf_path}")
        print("Please configure rclone first: rclone config")
        return None
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    # If no remote specified, find OneDrive remotes and prompt
    if rclone_remote is None:
        onedrive_remotes = find_onedrive_remotes()
        
        if not onedrive_remotes:
            print("Error: No OneDrive remotes found in rclone configuration")
            print("Please configure OneDrive first: rclone config")
            return None
        
        if len(onedrive_remotes) == 1:
            rclone_remote = onedrive_remotes[0]
            print(f"No share name given, seeking config file for the first entry that is OneDrive and found name: {rclone_remote}")
        else:
            print("No share name given, seeking config file for the first entry that is OneDrive.")
            print(f"Found {len(onedrive_remotes)} OneDrive remotes:")
            for i, remote in enumerate(onedrive_remotes, 1):
                print(f"  {i}. {remote}")
            
            # Use the first OneDrive remote
            rclone_remote = onedrive_remotes[0]
            print(f"Using first OneDrive remote: {rclone_remote}")
    
    if rclone_remote not in config:
        print(f"Error: Remote '{rclone_remote}' not found in {conf_path}")
        print(f"Available remotes: {list(config.sections())}")
        return None
    
    section = config[rclone_remote]
    token_json = section.get("token")
    if not token_json:
        print(f"Error: No token found for remote '{rclone_remote}' in {conf_path}")
        print("Please authenticate first: rclone authorize onedrive")
        return None
    
    try:
        token = json.loads(token_json)
    except Exception as e:
        print(f"Error: Could not parse token JSON: {e}")
        return None
    
    # Check if token is expired
    expiry_str = token.get("expiry")
    if expiry_str:
        try:
            # Parse the expiry time (format: 2025-07-23T15:50:44.457921153+10:00)
            expiry_time = datetime.fromisoformat(expiry_str)
            current_time = datetime.now(timezone.utc)
            
            # Convert expiry time to UTC if it has timezone info
            if expiry_time.tzinfo is not None:
                expiry_time_utc = expiry_time.astimezone(timezone.utc)
            else:
                expiry_time_utc = expiry_time.replace(tzinfo=timezone.utc)
            
            if current_time >= expiry_time_utc:
                print(f"❌ Error: Token has expired!")
                print(f"   Token expired on: {expiry_time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
                print(f"   Current time is: {current_time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
                print()
                print("To fix this, please refresh your rclone token:")
                print(f"   rclone config reconnect {rclone_remote}")
                print("Or re-authenticate completely:")
                print(f"   rclone config")
                return None
                
        except ValueError as e:
            print(f"Warning: Could not parse token expiry time '{expiry_str}': {e}")
            # Continue anyway in case the expiry format is different
    
    access_token = token.get("access_token")
    if not access_token:
        print("Error: No access_token in token JSON")
        print("Token may be expired. Please re-authenticate: rclone authorize onedrive")
        return None
    
    return access_token

def validate_remote_config(rclone_remote: str) -> bool:
    """
    Validate that a remote exists and has a valid token.
    
    Args:
        rclone_remote: Name of the OneDrive remote in rclone.conf
        
    Returns:
        True if remote is valid, False otherwise
    """
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    if not os.path.exists(conf_path):
        return False
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    if rclone_remote not in config:
        return False
    
    section = config[rclone_remote]
    token_json = section.get("token")
    if not token_json:
        return False
    
    try:
        token = json.loads(token_json)
        return bool(token.get("access_token"))
    except Exception:
        return False 