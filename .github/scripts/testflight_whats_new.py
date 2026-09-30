"""Set "What to Test" (whatsNew) of an uploaded build in TestFlight.

Usage: testflight_whats_new.py <bundle-id> <version> <build-number> <text-file>
Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, optional TESTFLIGHT_LOCALE
(only used when the build has no localization yet).

The build shows up in the API only after Apple accepted the upload, which takes minutes, so this polls for up to
WAIT_MINUTES. Same as in iDomi94/Lademonitor-App.
"""

import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
WAIT_MINUTES = 45
POLL_SECONDS = 30


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60,
         "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, **kwargs) -> dict:
    # a new token per call: it expires after 20 min, the wait takes longer
    resp = requests.request(method, API + path, timeout=60,
                            headers={"Authorization": f"Bearer {token()}"}, **kwargs)
    if resp.status_code >= 400:
        sys.exit(f"{method} {path} -> {resp.status_code}: {resp.text}")
    return resp.json() if resp.content else {}


def main() -> None:
    bundle_id, version, build_number, text_file = sys.argv[1:5]
    with open(text_file, encoding="utf-8") as f:
        whats_new = f.read().strip()[:4000]
    if not whats_new:
        print("No changelog text, nothing to do.")
        return

    apps = call("GET", "/apps", params={"filter[bundleId]": bundle_id})["data"]
    if not apps:
        sys.exit(f"No app with bundle id {bundle_id} in App Store Connect")
    app_id = apps[0]["id"]

    deadline = time.time() + WAIT_MINUTES * 60
    while True:
        builds = call("GET", "/builds", params={
            "filter[app]": app_id,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": version,
        })["data"]
        if builds:
            build_id = builds[0]["id"]
            break
        if time.time() > deadline:
            sys.exit(f"Build {version} ({build_number}) not found after {WAIT_MINUTES} min")
        print(f"Build {version} ({build_number}) not there yet, waiting ...")
        time.sleep(POLL_SECONDS)

    locs = call("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    if locs:
        for loc in locs:
            call("PATCH", f"/betaBuildLocalizations/{loc['id']}", json={"data": {
                "type": "betaBuildLocalizations", "id": loc["id"],
                "attributes": {"whatsNew": whats_new}}})
            print(f"whatsNew set ({loc['attributes']['locale']})")
    else:
        locale = os.environ.get("TESTFLIGHT_LOCALE") or "de-DE"
        call("POST", "/betaBuildLocalizations", json={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": locale, "whatsNew": whats_new},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print(f"whatsNew set ({locale}, created)")


if __name__ == "__main__":
    main()
