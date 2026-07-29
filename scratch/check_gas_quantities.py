import urllib.request
import json
import ssl
import time

GAS_URL = "https://script.google.com/macros/s/AKfycbx00z3FrpwH-31r4N_AV8Gd8RE2umRwlGMoFxVh4Zdq6jxhAVR1_xR6xsPlhzE-YYdx/exec"

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

if __name__ == "__main__":
    st = fetch_gas_state("26TESSALO")
    compras = st.get("meta", {}).get("compras", {}).get("registros", [])
    print("Total registros:", len(compras))
    total_qtd = sum(float(c.get("quantidade", 1)) for c in compras)
    print("Sum de quantidades:", total_qtd)
    for c in compras:
        if float(c.get("quantidade", 1)) != 1:
            print("  Item com quantidade != 1:", c)
        if "Jhonat" in c.get("nome", ""):
            print("  Jhonat item:", c)
