"""Revoke the signing certificates this CI run created.

xcodebuild -allowProvisioningUpdates makes a new development (and, if needed, distribution) certificate on every
fresh runner, because the runner's keychain is empty. They are useless once the runner is gone, and Apple caps the
number of certificates per team ("Your account has reached the maximum number of certificates"). This revokes
exactly the certificates whose SHA-1 is in the runner's keychain now but was not before the build - never a
certificate made on a developer's Mac.

Usage: revoke_run_certs.py <key-file> <sha1-file-before> <sha1-file-after>
Environment: ASC_KEY_ID, ASC_ISSUER_ID
"""

import base64
import hashlib
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"


def hashes(path: str) -> set[str]:
    try:
        with open(path, encoding="utf-8") as f:
            return {line.strip().upper() for line in f if line.strip()}
    except FileNotFoundError:
        return set()


def main() -> None:
    key_file, before_file, after_file = sys.argv[1:4]
    new = hashes(after_file) - hashes(before_file)
    if not new:
        print("No certificate was created in this run.")
        return
    with open(key_file, encoding="utf-8") as f:
        pem = f.read()
    now = int(time.time())
    token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 10 * 60,
                        "aud": "appstoreconnect-v1"},
                       pem, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})
    auth = {"Authorization": f"Bearer {token}"}
    resp = requests.get(API + "/certificates", headers=auth, timeout=60,
                        params={"limit": 200, "fields[certificates]": "certificateContent,displayName,certificateType"})
    resp.raise_for_status()
    for cert in resp.json()["data"]:
        a = cert["attributes"]
        der = base64.b64decode(a.get("certificateContent") or "")
        if hashlib.sha1(der).hexdigest().upper() not in new:
            continue
        r = requests.delete(f"{API}/certificates/{cert['id']}", headers=auth, timeout=60)
        if r.ok:
            print(f"Revoked {a.get('certificateType')} {a.get('displayName')} (made by this run)")
        else:
            print(f"::warning::Could not revoke {a.get('displayName')}: {r.status_code} {r.text}")


if __name__ == "__main__":
    main()
