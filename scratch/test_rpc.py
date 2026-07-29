import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def rpc(fn_name, payload):
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/rpc/{fn_name}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            print(f"RPC '{fn_name}' result keys:", list(res.keys()) if isinstance(res, dict) else res)
            print("Full result:", json.dumps(res, indent=2, ensure_ascii=False)[:500])
    except urllib.error.HTTPError as e:
        print(f"HTTPError in '{fn_name}':", e.code, e.read().decode('utf-8'))
    except Exception as e:
        print(f"Error in '{fn_name}':", e)

if __name__ == "__main__":
    print("Testing fn_login_admin with 'admin123':")
    rpc("fn_login_admin", {"p_admin_senha": "admin123"})
    print("\nTesting fn_login_admin with '26TESSALO':")
    rpc("fn_login_admin", {"p_admin_senha": "26TESSALO"})
