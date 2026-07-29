import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def fix_jhonathan():
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    # 1. Update compras
    print("Updating compras for Jhonatan -> Jhonathan...")
    url = f"{SUPABASE_URL}/rest/v1/compras?nome=eq.Jhonatan"
    req = urllib.request.Request(url, data=json.dumps({"nome": "Jhonathan"}).encode("utf-8"), headers=headers, method="PATCH")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            print("  Compras updated, status:", resp.status)
    except Exception as e:
        print("  Error updating compras:", e)

    # 2. Update historico pagador
    print("Updating historico pagador...")
    url = f"{SUPABASE_URL}/rest/v1/historico?pagador=eq.Jhonatan"
    req = urllib.request.Request(url, data=json.dumps({"pagador": "Jhonathan"}).encode("utf-8"), headers=headers, method="PATCH")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            print("  Historico pagador updated, status:", resp.status)
    except Exception as e:
        print("  Error updating historico pagador:", e)

    # 3. Update historico ator
    print("Updating historico ator...")
    url = f"{SUPABASE_URL}/rest/v1/historico?ator=eq.Jhonatan"
    req = urllib.request.Request(url, data=json.dumps({"ator": "Jhonathan"}).encode("utf-8"), headers=headers, method="PATCH")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            print("  Historico ator updated, status:", resp.status)
    except Exception as e:
        print("  Error updating historico ator:", e)

    # 4. Check pessoas table
    url_p = f"{SUPABASE_URL}/rest/v1/pessoas?select=id,nome"
    req_p = urllib.request.Request(url_p, headers=headers)
    with urllib.request.urlopen(req_p, context=ctx) as resp:
        pessoas = json.loads(resp.read().decode("utf-8"))
        print("Pessoas na tabela:", [p["nome"] for p in pessoas])

if __name__ == "__main__":
    fix_jhonathan()
