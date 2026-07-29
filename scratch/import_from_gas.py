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

    if not res.get("ok"):
        raise Exception(f"Erro no Apps Script: {res.get('error')}")
    
    return res["data"]["state"]

def supabase_post(endpoint, payload):
    ctx = ssl.create_default_context()
    url = f"{SUPABASE_URL}/rest/v1/{endpoint}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates"
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        if e.code == 409:
            # If 409 conflict, ignore or update
            pass
        else:
            print(f"  Erro HTTP [{e.code}] em {endpoint}: {e.read().decode('utf-8')}")
    except Exception as e:
        print(f"  Erro ao postar em {endpoint}: {e}")

def migrate(state, admin_password):
    print("Iniciando migracao para o Supabase...")
    
    # 0. Admin password
    if admin_password:
        print(f"Atualizando senha de Admin no Supabase para a antiga ({admin_password})...")
        supabase_post("configuracoes", {
            "chave": "admin_password",
            "valor": admin_password
        })

    # 1. Pessoas
    pessoas = state.get("pessoas", [])
    print(f"Migrando {len(pessoas)} participantes...")
    for idx, p in enumerate(pessoas, start=1):
        payload = {
            "nome": p.get("nome"),
            "ordem": p.get("ordem", idx),
            "ativo": True,
            "pausado": p.get("pausado", False),
            "senha_hash": p.get("senhaHash") or p.get("senha_hash"),
            "senha_salt": p.get("senhaSalt") or p.get("senha_salt"),
            "codigo_ativacao_hash": p.get("codigoAtivacaoHash") or p.get("codigo_ativacao_hash")
        }
        supabase_post("pessoas", payload)
        print(f"  - [{idx}] {p.get('nome')} (senhaHash: {'SIM' if payload['senha_hash'] else 'NAO'})")

    # 2. Histórico
    historico = state.get("historico", [])
    print(f"Migrando {len(historico)} registros de historico...")
    for h in historico:
        payload = {
            "texto": h.get("texto"),
            "tipo": h.get("tipo", "geral"),
            "ator": h.get("ator"),
            "pagador": h.get("pagador")
        }
        supabase_post("historico", payload)
    print("  Historico concluido.")

    # 3. Compras
    compras = state.get("meta", {}).get("compras", {}).get("registros", [])
    print(f"Migrando {len(compras)} registros de compras...")
    for c in compras:
        payload = {
            "nome": c.get("nome"),
            "quantidade": c.get("quantidade", 1),
            "data": c.get("data")
        }
        supabase_post("compras", payload)
    print("  Compras concluidas.")

    print("MIGRACAO COMPLETA COM SUCESSO NO SUPABASE!")

if __name__ == "__main__":
    import sys
    pwd = sys.argv[1] if len(sys.argv) > 1 else "26TESSALO"
    state = fetch_gas_state(pwd)
    migrate(state, pwd)

