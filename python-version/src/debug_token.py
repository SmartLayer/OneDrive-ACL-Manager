#!/usr/bin/env python3
"""
Debug script to examine the token format from rclone.conf
"""

import configparser
import json
import os
import base64

def examine_rclone_token(rclone_remote: str = "OneDrive-ACL"):
    """Examine the token structure in rclone.conf"""
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    
    print(f"=== Examining rclone token format ===")
    print(f"Config path: {conf_path}")
    print(f"Remote: {rclone_remote}")
    print()
    
    if not os.path.exists(conf_path):
        print(f"❌ Config file not found: {conf_path}")
        return
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    if rclone_remote not in config:
        print(f"❌ Remote '{rclone_remote}' not found")
        print(f"Available remotes: {list(config.sections())}")
        return
    
    section = config[rclone_remote]
    token_json = section.get("token")
    
    if not token_json:
        print(f"❌ No token found for remote '{rclone_remote}'")
        return
    
    print(f"Raw token JSON length: {len(token_json)} characters")
    print(f"First 100 chars: {token_json[:100]}...")
    print()
    
    try:
        token = json.loads(token_json)
        print("✅ Successfully parsed token JSON")
        print(f"Token keys: {list(token.keys())}")
        print()
        
        # Examine each token field
        for key, value in token.items():
            print(f"=== {key} ===")
            if isinstance(value, str):
                print(f"Type: string")
                print(f"Length: {len(value)} characters")
                print(f"First 50 chars: {value[:50]}...")
                
                # Check if it looks like a JWT (has dots)
                if '.' in value:
                    parts = value.split('.')
                    print(f"Has {len(parts)} parts (JWT format)")
                    
                    # Try to decode JWT parts
                    for i, part in enumerate(parts):
                        try:
                            # Add padding if needed for base64 decoding
                            padded = part + '=' * (4 - len(part) % 4)
                            decoded = base64.urlsafe_b64decode(padded)
                            print(f"  Part {i+1}: {decoded.decode('utf-8', errors='ignore')[:100]}...")
                        except Exception as e:
                            print(f"  Part {i+1}: Could not decode - {e}")
                else:
                    print("No dots found - not JWT format")
            else:
                print(f"Type: {type(value)}")
                print(f"Value: {value}")
            print()
            
    except Exception as e:
        print(f"❌ Could not parse token JSON: {e}")

def test_different_token_fields():
    """Test making API calls with different token fields"""
    conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
    rclone_remote = "OneDrive-ACL"
    
    if not os.path.exists(conf_path):
        return
    
    config = configparser.ConfigParser()
    config.read(conf_path)
    
    if rclone_remote not in config:
        return
    
    section = config[rclone_remote]
    token_json = section.get("token")
    
    if not token_json:
        return
    
    try:
        token = json.loads(token_json)
        
        # Test each token field with a simple API call
        import requests
        
        test_url = "https://graph.microsoft.com/v1.0/me"
        
        for key, value in token.items():
            if isinstance(value, str) and len(value) > 10:  # Only test string values
                print(f"=== Testing {key} ===")
                headers = {"Authorization": f"Bearer {value}"}
                
                try:
                    resp = requests.get(test_url, headers=headers, timeout=10)
                    print(f"Status: {resp.status_code}")
                    
                    if resp.status_code == 200:
                        print("✅ SUCCESS! This token works")
                        user_data = resp.json()
                        print(f"User: {user_data.get('displayName', 'Unknown')}")
                        return key, value
                    else:
                        print(f"❌ Failed: {resp.text[:200]}...")
                        
                except Exception as e:
                    print(f"❌ Error: {e}")
                print()
                
    except Exception as e:
        print(f"❌ Could not parse token: {e}")
    
    return None, None

if __name__ == "__main__":
    examine_rclone_token()
    print("\n" + "="*60 + "\n")
    print("=== Testing different token fields ===")
    working_key, working_token = test_different_token_fields()
    
    if working_key:
        print(f"\n✅ Found working token field: {working_key}")
    else:
        print(f"\n❌ No working token field found") 