import urllib.request
import json
import ssl
import hashlib
import uuid

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def set_passwords_for_all():
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    # Fetch all pessoas
    req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/pessoas?select=id,nome,senha_hash", headers=headers)
    with urllib.request.urlopen(req, context=ctx) as resp:
        pessoas = json.loads(resp.read().decode("utf-8"))

    default_pwd = "123456"
    for p in pessoas:
        if not p.get("senha_hash"):
            salt = str(uuid.uuid4())
            to_hash = f"{salt}:{default_pwd}".encode("utf-8")
            h = hashlib.sha256(to_hash).hexdigest()
            
            patch_data = json.dumps({"senha_hash": h, "senha_salt": salt}).encode("utf-8")
            url = f"{SUPABASE_URL}/rest/v1/pessoas?id=eq.{p['id']}"
            patch_req = urllib.request.Request(url, data=patch_data, headers=headers, method="PATCH")
            with urllib.request.urlopen(patch_req, context=ctx) as r:
                print(f"Set password for {p['nome']} (pwd: {default_pwd}), status: {r.status}")
        else:
            print(f"{p['nome']} já possui senha cadastrada.")

if __name__ == "__main__":
    set_passwords_for_all()
