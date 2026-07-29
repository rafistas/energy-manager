import urllib.request
import json
import ssl

class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def fetch_gas():
    ctx = ssl.create_default_context()
    opener = urllib.request.build_opener(NoRedirectHandler)
    url = "https://script.google.com/macros/s/AKfycbx00z3FrpwH-31r4N_AV8Gd8RE2umRwlGMoFxVh4Zdq6jxhAVR1_xR6xsPlhzE-YYdx/exec"
    payload = json.dumps({
        "action": "loginAdmin",
        "adminSenha": "26TESSALO",
        "requestId": "req_mig_01"
    }).encode("utf-8")
    
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "text/plain;charset=utf-8"}, method="POST")
    
    try:
        resp = opener.open(req)
        print("Resp:", resp.read().decode("utf-8")[:300])
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            redirect_url = e.headers.get("Location")
            print("Redirect URL:", redirect_url)
            # Google Apps Script includes output in the redirect response or allows GET on redirect URL
            req2 = urllib.request.Request(redirect_url, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req2, context=ctx) as resp2:
                print("Final Data:", resp2.read().decode("utf-8")[:500])

fetch_gas()
