import urllib.request
import json
import ssl

SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyNTU3ODAsImV4cCI6MjEwMDgzMTc4MH0.mAciU6FJGRHxCKIwuC6aRv4t0KGtiuvbX2kmM4M6oZI"

def test_anon_rpc():
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/rpc/fn_get_state"
    headers = {
        "apikey": ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
        "Content-Type": "application/json"
    }
    data = json.dumps({"p_session_person": None}).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            print("ANON RPC fn_get_state result:")
            print("Pessoas count:", len(res.get("pessoas", [])))
            print("Historico count:", len(res.get("historico", [])))
            print("Compras count:", len(res.get("meta", {}).get("compras", {}).get("registros", [])))
    except urllib.error.HTTPError as e:
        print("HTTPError with ANON key:", e.code, e.read().decode('utf-8'))
    except Exception as e:
        print("Error with ANON key:", e)

if __name__ == "__main__":
    test_anon_rpc()
