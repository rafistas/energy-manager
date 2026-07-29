import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def add_pending_payment():
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    # First clear existing pendencias just in case
    del_req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/pendencias?status=eq.PENDENTE", headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(del_req, context=ctx) as resp:
            pass
    except Exception as e:
        print("Delete pendencias info:", e)

    # Insert pending payment matching production
    payload = {
        "tipo": "Compra extra aprovada por votacao",
        "status": "PENDENTE",
        "observacao": "Votos SIM: 4, votos NAO: 0.",
        "valor": 17.50,
        "origem": "votacao"
    }
    post_req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/pendencias", data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")
    with urllib.request.urlopen(post_req, context=ctx) as resp:
        print("Inserted pending payment, status:", resp.status)

if __name__ == "__main__":
    add_pending_payment()
