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
            print(f"SUCCESS '{fn_name}':")
            print("Pessoas count:", len(res.get("pessoas", [])))
            print("Pessoas:", res.get("pessoas"))
            print("Historico count:", len(res.get("historico", [])))
            print("Compras count:", len(res.get("meta", {}).get("compras", {}).get("registros", [])))
    except urllib.error.HTTPError as e:
        print(f"HTTPError in '{fn_name}':", e.code, e.read().decode('utf-8'))
    except Exception as e:
        print(f"Error in '{fn_name}':", e)

if __name__ == "__main__":
    print("Testing fn_get_state with null:")
    rpc("fn_get_state", {"p_session_person": None})
