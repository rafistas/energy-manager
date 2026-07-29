import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def fix_date_29_to_28():
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    url = f"{SUPABASE_URL}/rest/v1/compras?data=eq.2026-07-29"
    payload = {"data": "2026-07-28"}
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="PATCH")
    with urllib.request.urlopen(req, context=ctx) as resp:
        print("Updated purchase date from 2026-07-29 to 2026-07-28: status", resp.status)

if __name__ == "__main__":
    fix_date_29_to_28()
