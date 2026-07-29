import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def get(table):
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/{table}?select=*"
    req = urllib.request.Request(url, headers={
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}"
    })
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            print(f"Table '{table}': {len(data)} items")
            if data:
                print("  Sample item:", data[0])
    except Exception as e:
        print(f"Error reading '{table}': {e}")

if __name__ == "__main__":
    get("pessoas")
    get("historico")
    get("configuracoes")
    get("compras")
