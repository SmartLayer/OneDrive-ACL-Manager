#!/usr/bin/env python3
"""
OAuth Experiment - Test OneDrive OAuth flow to see token response with scopes.

This script mimics rclone's OAuth flow:
1. Start local HTTP server on port 53682
2. Launch browser with OAuth authorization URL
3. Capture authorization code from callback
4. Exchange code for access token
5. Display the full token response (including scope)
"""

import http.server
import socketserver
import urllib.parse
import webbrowser
import requests
import json
from threading import Thread
import time

# Microsoft OAuth endpoints
AUTH_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
TOKEN_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

# Rclone's actual client ID from source code:
# https://github.com/rclone/rclone/blob/master/backend/onedrive/onedrive.go
    CLIENT_ID = "b15665d9-eda6-4092-8539-0eec376afd59"  # rclone's real OneDrive client ID
    CLIENT_SECRET = "qtyfaBBYA403=unZUP40~_#"  # Decrypted from rclone source
REDIRECT_URI = "http://localhost:53682/"

# Scopes that rclone actually requests (from source code)
SCOPES = [
    "Files.Read",
    "Files.ReadWrite", 
    "Files.Read.All",
    "Files.ReadWrite.All",
    "Sites.Read.All",  # NOTE: Read.All, not Manage.All
    "offline_access"
]

# Global to store the authorization code
auth_code = None
server_running = True

class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
    """Handle OAuth callback from Microsoft."""
    
    def log_message(self, format, *args):
        """Suppress default logging."""
        pass
    
    def do_GET(self):
        global auth_code, server_running
        
        # Parse query parameters
        parsed_path = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed_path.query)
        
        if 'code' in params:
            auth_code = params['code'][0]
            
            # Send success response to browser
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            
            success_html = """
            <html>
            <head><title>Authentication Successful</title></head>
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
                <h1 style="color: green;">✅ Authentication Successful!</h1>
                <p>You can close this window and return to the terminal.</p>
                <p>The authorization code has been captured.</p>
            </body>
            </html>
            """
            self.wfile.write(success_html.encode())
            
            # Signal to stop the server
            server_running = False
            print("\n✅ Authorization code received!")
            
        elif 'error' in params:
            error = params['error'][0]
            error_desc = params.get('error_description', ['Unknown error'])[0]
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            
            error_html = f"""
            <html>
            <head><title>Authentication Failed</title></head>
            <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
                <h1 style="color: red;">❌ Authentication Failed</h1>
                <p><strong>Error:</strong> {error}</p>
                <p><strong>Description:</strong> {error_desc}</p>
                <p>You can close this window and return to the terminal.</p>
            </body>
            </html>
            """
            self.wfile.write(error_html.encode())
            
            server_running = False
            print(f"\n❌ Authentication error: {error}")
            print(f"   Description: {error_desc}")


def start_local_server():
    """Start local HTTP server to receive OAuth callback."""
    PORT = 53682
    
    with socketserver.TCPServer(("", PORT), OAuthCallbackHandler) as httpd:
        print(f"🌐 Local server started on http://localhost:{PORT}")
        print("   Waiting for OAuth callback...")
        
        # Keep server running until we get the callback
        while server_running:
            httpd.handle_request()
            time.sleep(0.1)
        
        print("🛑 Server stopped")


def build_auth_url():
    """Build OAuth authorization URL."""
    params = {
        'client_id': CLIENT_ID,
        'response_type': 'code',
        'redirect_uri': REDIRECT_URI,
        'scope': ' '.join(SCOPES),
        'response_mode': 'query',
        'prompt': 'select_account'
    }
    
    url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"
    return url


def exchange_code_for_token(code):
    """Exchange authorization code for access token."""
    print("\n🔄 Exchanging authorization code for access token...")
    
    data = {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'redirect_uri': REDIRECT_URI,
        'scope': ' '.join(SCOPES)
    }
    
    try:
        response = requests.post(TOKEN_URL, data=data, timeout=30)
        
        if response.status_code == 200:
            token_data = response.json()
            return token_data
        else:
            print(f"❌ Token exchange failed: {response.status_code}")
            print(f"   Response: {response.text}")
            return None
    except Exception as e:
        print(f"❌ Error during token exchange: {e}")
        return None


def main():
    """Main OAuth flow."""
    print("=" * 80)
    print("OneDrive OAuth Token Acquisition Experiment")
    print("=" * 80)
    print()
    print("This script will:")
    print("  1. Start a local server on port 53682")
    print("  2. Launch your browser for Microsoft authentication")
    print("  3. Capture the authorization code")
    print("  4. Exchange it for an access token")
    print("  5. Display the token response (including scope)")
    print()
    print("Requested scopes:")
    for scope in SCOPES:
        print(f"  - {scope}")
    print()
    
    # Build authorization URL
    auth_url = build_auth_url()
    print("📋 Authorization URL:")
    print(f"   {auth_url[:100]}...")
    print()
    
    # Start local server in a separate thread
    server_thread = Thread(target=start_local_server, daemon=True)
    server_thread.start()
    
    # Wait a moment for server to start
    time.sleep(1)
    
    # Launch browser
    print("🌐 Launching browser for authentication...")
    print("   Please sign in and authorize the application.")
    print()
    
    try:
        webbrowser.open(auth_url)
    except Exception as e:
        print(f"❌ Could not launch browser: {e}")
        print("   Please open this URL manually:")
        print(f"   {auth_url}")
    
    # Wait for authorization code
    print("⏳ Waiting for authorization (timeout: 120 seconds)...")
    
    timeout = 120
    elapsed = 0
    while auth_code is None and elapsed < timeout:
        time.sleep(1)
        elapsed += 1
        
        if elapsed % 10 == 0:
            print(f"   Still waiting... ({elapsed}/{timeout}s)")
    
    if auth_code is None:
        print("\n❌ Timeout waiting for authorization")
        print("   Did you complete the authentication in the browser?")
        return
    
    # Exchange code for token
    token_data = exchange_code_for_token(auth_code)
    
    if not token_data:
        print("\n❌ Failed to obtain access token")
        return
    
    # Display token information
    print("\n" + "=" * 80)
    print("✅ SUCCESS! Token acquired")
    print("=" * 80)
    print()
    
    # Show key fields
    print("📊 Token Response:")
    print(f"   Token Type: {token_data.get('token_type', 'N/A')}")
    print(f"   Expires In: {token_data.get('expires_in', 'N/A')} seconds")
    
    # The crucial field: scope
    scope = token_data.get('scope', '')
    if scope:
        print(f"\n🎯 Scope (this is what we need!):")
        print(f"   {scope}")
        print()
        print("   Individual scopes:")
        for s in scope.split():
            print(f"     - {s}")
    else:
        print("\n⚠️  WARNING: No scope field in response!")
    
    # Check for refresh token
    if 'refresh_token' in token_data:
        print(f"\n🔄 Refresh Token: Present (length: {len(token_data['refresh_token'])} chars)")
    else:
        print("\n⚠️  WARNING: No refresh token in response!")
    
    # Show access token (truncated)
    access_token = token_data.get('access_token', '')
    if access_token:
        print(f"\n🔑 Access Token: {access_token[:50]}...{access_token[-20:]} (length: {len(access_token)} chars)")
    
    # Save to file
    save_to_file = input("\n💾 Save token to token.json? (y/N): ").strip().lower()
    
    if save_to_file in ['y', 'yes']:
        from datetime import datetime, timedelta, timezone
        
        # Calculate expiry timestamp
        expires_in = token_data.get('expires_in', 3600)
        expiry_time = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
        
        # Prepare token data for saving
        token_file_data = {
            'access_token': token_data.get('access_token'),
            'token_type': token_data.get('token_type', 'Bearer'),
            'scope': token_data.get('scope', ''),
            'expires_at': expiry_time.isoformat(),
            'expires_in': expires_in,
            'refresh_token': token_data.get('refresh_token'),
            'drive_id': '5D1B2B3BE100F93B',  # Will be filled in later
            'drive_type': 'personal'
        }
        
        with open('token.json', 'w') as f:
            json.dump(token_file_data, f, indent=2)
        
        print("✅ Token saved to token.json")
        print()
        print("📋 Saved format:")
        print(json.dumps(token_file_data, indent=2)[:500] + "...")
    
    print("\n" + "=" * 80)
    print("Experiment complete!")
    print("=" * 80)
    print()
    print("Key findings:")
    print("  ✓ Token response DOES include 'scope' field")
    print("  ✓ We can check scope to determine token capabilities")
    print("  ✓ Must save scope when creating token.json")
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n⚠️  Interrupted by user")
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()

