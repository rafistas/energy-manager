import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

def fix_ordem():
    ctx = ssl.create_default_context()
    pessoas_ordem = [
        ("Breno", 1),
        ("Felipe", 2),
        ("Rafael", 3),
        ("Sardinha", 4),
        ("Hugo", 5),
        ("Leonardo", 6),
        ("Jhonathan", 7)
    ]
    for nome, ordem in pessoas_ordem:
        url = f"{SUPABASE_URL}/rest/v1/pessoas?nome=eq.{nome}"
        req = urllib.request.Request(
            url,
            data=json.dumps({"ordem": ordem}).encode("utf-8"),
            headers={
                "apikey": SERVICE_KEY,
                "Authorization": f"Bearer {SERVICE_KEY}",
                "Content-Type": "application/json"
            },
            method="PATCH"
        )
        with urllib.request.urlopen(req, context=ctx) as resp:
            print(f"Updated {nome} -> ordem {ordem}: status {resp.status}")

if __name__ == "__main__":
    fix_ordem()
