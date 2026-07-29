import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def reset_passwords_for_first_access():
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    url = f"{SUPABASE_URL}/rest/v1/pessoas?id=neq.00000000-0000-0000-0000-000000000000"
    payload = {
        "senha_hash": None,
        "senha_salt": None,
        "codigo_ativacao_hash": None
    }
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="PATCH")
    with urllib.request.urlopen(req, context=ctx) as resp:
        print("Reset all participant passwords to NULL (first access mode): status", resp.status)

if __name__ == "__main__":
    reset_passwords_for_first_access()
