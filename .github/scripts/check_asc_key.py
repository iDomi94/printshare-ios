"""Check the App Store Connect API key before xcodebuild uses it.

xcodebuild only says "Authentication failed: Make sure a bearer token was provided ..." when the key, its id, the
issuer id or its role do not fit. This calls the API with the same key and says which part is wrong, and whether
the app record and the bundle ids exist.

Usage: check_asc_key.py <bundle-id> <key-file>
Environment: ASC_KEY_ID, ASC_ISSUER_ID
"""

import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"


def main() -> None:
    bundle_id, key_file = sys.argv[1:3]
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    print(f"Key id: {len(key_id)} characters, issuer id: {len(issuer)} characters")
    if len(key_id) != 10:
        print("::warning::ASC_KEY_ID should be the 10-character key id (from AuthKey_<id>.p8)")
    if len(issuer) != 36:
        print("::warning::ASC_ISSUER_ID should be a UUID (36 characters, shown above the team keys); "
              "individual keys have no issuer id and do not work with xcodebuild")
    with open(key_file, encoding="utf-8") as f:
        pem = f.read()
    now = int(time.time())
    try:
        token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 10 * 60, "aud": "appstoreconnect-v1"},
                           pem, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
    except Exception as exc:  # noqa: BLE001 - any failure here means the .p8 is unusable
        sys.exit(f"::error::ASC_KEY_P8 cannot sign a token: {exc}")

    def get(path: str, **params) -> requests.Response:
        return requests.get(API + path, params=params, timeout=60, headers={"Authorization": f"Bearer {token}"})

    resp = get("/apps", **{"filter[bundleId]": bundle_id})
    if resp.status_code == 401:
        sys.exit("::error::App Store Connect rejects the key (401). ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 "
                 "do not belong together, or the key was revoked. Use a team key (Users and Access -> Integrations "
                 "-> App Store Connect API -> Team Keys), its key id and the issuer id shown there.")
    if resp.status_code == 403:
        sys.exit(f"::error::The key is valid but not allowed to read apps (403): {resp.text}")
    resp.raise_for_status()
    print("Key accepted by App Store Connect.")
    if resp.json()["data"]:
        print(f"App record for {bundle_id} found.")
    else:
        print(f"::warning::No app record for {bundle_id} in App Store Connect yet - the upload will fail until the "
              "app is created there (Apps -> + -> New App).")

    resp = get("/bundleIds", **{"filter[identifier]": f"{bundle_id},{bundle_id}.share-extension"})
    if resp.status_code == 403:
        sys.exit("::error::The key may not manage certificates and profiles (403 on bundle ids). Give it the role "
                 "Admin, or App Manager with access to Certificates, Identifiers & Profiles.")
    resp.raise_for_status()
    found = sorted(item["attributes"]["identifier"] for item in resp.json()["data"])
    print(f"Registered bundle ids: {found or 'none yet (automatic signing registers them)'}")

    # Every run on a fresh runner makes a new development certificate for the archive; Apple caps their number.
    resp = get("/certificates", limit=200, **{"fields[certificates]": "name,displayName,certificateType,expirationDate"})
    if resp.ok:
        certs = resp.json()["data"]
        dev = [c["attributes"] for c in certs
               if c["attributes"].get("certificateType") in ("DEVELOPMENT", "IOS_DEVELOPMENT")]
        print(f"Certificates: {len(certs)}, development: {len(dev)}")
        for a in dev:
            print(f"  {a.get('certificateType')}: {a.get('displayName') or a.get('name')} "
                  f"(expires {str(a.get('expirationDate'))[:10]})")


if __name__ == "__main__":
    main()
