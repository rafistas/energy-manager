import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def check_compras_grouped():
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/compras?select=*"
    req = urllib.request.Request(url, headers={
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}"
    })
    with urllib.request.urlopen(req, context=ctx) as resp:
        compras = json.loads(resp.read().decode('utf-8'))
        tally = {}
        for c in compras:
            n = c["nome"]
            tally[n] = tally.get(n, 0) + float(c.get("quantidade", 1))
        print("Tally por participante no banco:")
        for n, qtd in sorted(tally.items()):
            print(f"  {n}: {int(qtd)} unidades")
        print(f"Total geral: {int(sum(tally.values()))} unidades")

if __name__ == "__main__":
    check_compras_grouped()
