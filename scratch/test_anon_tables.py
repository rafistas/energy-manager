import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyNTU3ODAsImV4cCI6MjEwMDgzMTc4MH0.mAciU6FJGRHxCKIwuC6aRv4t0KGtiuvbX2kmM4M6oZI"

def test_anon_table(table):
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/{table}?select=*"
    headers = {
        "apikey": ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}"
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            print(f"ANON read '{table}': {len(data)} items")
    except urllib.error.HTTPError as e:
        print(f"ANON read '{table}' HTTPError:", e.code, e.read().decode('utf-8'))
    except Exception as e:
        print(f"ANON read '{table}' Error:", e)

if __name__ == "__main__":
    test_anon_table("pessoas")
    test_anon_table("historico")
    test_anon_table("configuracoes")
    test_anon_table("compras")
