import urllib.request
import json
import ssl
import time

GAS_URL = "https://script.google.com/macros/s/AKfycbx00z3FrpwH-31r4N_AV8Gd8RE2umRwlGMoFxVh4Zdq6jxhAVR1_xR6xsPlhzE-YYdx/exec"
SUPABASE_URL = "https://gmmxgjtlvilowwcudypm.supabase.co"
SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdtbXhnanRsdmlsb3d3Y3VkeXBtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NTI1NTc4MCwiZXhwIjoyMTAwODMxNzgwfQ.OSMtGFjaTlrEHaPWIAdXCfheGXPwO4ZxJ4L9AwUjaG0"

class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def fetch_gas_state(admin_password):
    ctx = ssl.create_default_context()
    opener = urllib.request.build_opener(NoRedirectHandler)
    payload = json.dumps({
        "action": "loginAdmin",
        "adminSenha": admin_password,
        "requestId": f"mig_{int(time.time())}"
    }).encode("utf-8")
    
    req = urllib.request.Request(GAS_URL, data=payload, headers={"Content-Type": "text/plain;charset=utf-8"}, method="POST")
    try:
        resp = opener.open(req)
        res = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            redirect_url = e.headers.get("Location")
            req2 = urllib.request.Request(redirect_url)
            with urllib.request.urlopen(req2, context=ctx) as resp2:
                res = json.loads(resp2.read().decode("utf-8"))
        else:
            raise e
    return res["data"]["state"]

def reset_and_import_compras(state):
    ctx = ssl.create_default_context()
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }

    # 1. Apagar todas as compras existentes
    print("Apagando compras duplicadas do Supabase...")
    del_req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/compras?id=neq.00000000-0000-0000-0000-000000000000", headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(del_req, context=ctx) as resp:
            print("  Compras apagadas, status:", resp.status)
    except Exception as e:
        print("  Erro ao apagar compras:", e)

    # 2. Inserir exatamente as compras do GAS
    compras = state.get("meta", {}).get("compras", {}).get("registros", [])
    print(f"Inserindo exatamente as {len(compras)} compras da producao...")
    for idx, c in enumerate(compras, 1):
        payload = {
            "nome": c.get("nome"),
            "quantidade": c.get("quantidade", 1),
            "data": c.get("data")
        }
        post_data = json.dumps(payload).encode("utf-8")
        post_req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/compras", data=post_data, headers=headers, method="POST")
        with urllib.request.urlopen(post_req, context=ctx) as resp:
            pass
        print(f"  - [{idx}/{len(compras)}] {c.get('nome')} em {c.get('data')}")

    print("CONCLUÍDO COM SUCESSO!")

if __name__ == "__main__":
    st = fetch_gas_state("26TESSALO")
    reset_and_import_compras(st)
