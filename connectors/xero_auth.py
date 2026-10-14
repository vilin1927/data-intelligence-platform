import requests
import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from base64 import b64encode

# Read from environment variables - no hardcoded credentials
CLIENT_ID = os.environ.get("XERO_CLIENT_ID")
CLIENT_SECRET = os.environ.get("XERO_CLIENT_SECRET")
REDIRECT_URI = os.environ.get("XERO_REDIRECT_URI", "http://localhost:8080/callback")

# Validate required env vars
if not CLIENT_ID:
    print("ERROR: XERO_CLIENT_ID environment variable is required", file=sys.stderr)
    sys.exit(1)
if not CLIENT_SECRET:
    print("ERROR: XERO_CLIENT_SECRET environment variable is required", file=sys.stderr)
    sys.exit(1)
SCOPES = "openid profile email offline_access accounting.invoices.read accounting.settings.read accounting.contacts.read"

AUTH_URL = (
    f"https://login.xero.com/identity/connect/authorize"
    f"?response_type=code"
    f"&client_id={CLIENT_ID}"
    f"&redirect_uri={REDIRECT_URI}"
    f"&scope={SCOPES.replace(' ', '%20')}"
    f"&state=moppity123"
)

print("\n=== SEND THIS URL TO THE OWNER ===")
print(AUTH_URL)
print("==============================\n")
print("Waiting for callback on port 8080...\n")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        params = parse_qs(urlparse(self.path).query)
        code = params.get('code', [''])[0]

        if not code:
            print("No code received.")
            self.send_response(400)
            self.end_headers()
            return

        print(f"Got auth code: {code}")
        self.send_response(200)
        self.send_header("ngrok-skip-browser-warning", "true")
        self.end_headers()
        self.wfile.write(b"<h1>Done! You can close this tab.</h1>")

        # Exchange code for tokens
        credentials = b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
        response = requests.post(
            "https://identity.xero.com/connect/token",
            headers={
                "Authorization": f"Basic {credentials}",
                "Content-Type": "application/x-www-form-urlencoded"
            },
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": REDIRECT_URI,
            }
        )

        tokens = response.json()
        print(f"\nTokens received: {json.dumps(tokens, indent=2)}")

        # Get tenant IDs
        tenants_response = requests.get(
            "https://api.xero.com/connections",
            headers={"Authorization": f"Bearer {tokens['access_token']}"}
        )
        tenants = tenants_response.json()
        print(f"\nXero organisations connected:")
        for t in tenants:
            print(f"  - {t['tenantName']} | tenant_id: {t['tenantId']}")

        # Save tokens to file
        with open("xero_tokens.json", "w") as f:
            json.dump({"tokens": tokens, "tenants": tenants}, f, indent=2)
        print("\nTokens saved to xero_tokens.json")

    def log_message(self, format, *args):
        pass  # suppress request logs


HTTPServer(('', 8080), Handler).serve_forever()
