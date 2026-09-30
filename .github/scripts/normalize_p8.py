"""Print the App Store Connect key from ASC_KEY_P8 as clean PEM.

Accepts the complete .p8, only the Base64 block inside it, Base64 of the whole file, Windows line endings and
literal "\\n". Stops with a readable message instead of handing xcodebuild a broken key (invalidPEMDocument).
Same as in iDomi94/Lademonitor-App.
"""

import base64
import os
import re
import sys

raw = os.environ.get("ASC_KEY_P8", "").replace("\\n", "\n").replace("\r", "").strip()
if not raw:
    sys.exit("Secret ASC_KEY_P8 is empty or not set.")

if "-----BEGIN" not in raw:
    # maybe the whole file Base64-encoded?
    try:
        decoded = base64.b64decode(raw, validate=False).decode("utf-8")
        if "-----BEGIN" in decoded:
            raw = decoded
    except Exception:
        pass

body = re.sub(r"-----(BEGIN|END)[^-]*-----", "", raw)
body = re.sub(r"\s+", "", body)
if not body:
    sys.exit("ASC_KEY_P8 contains no key.")
try:
    der = base64.b64decode(body, validate=True)
except Exception:
    sys.exit("ASC_KEY_P8 is not valid Base64 - paste the contents of the .p8 unchanged.")
if len(der) < 100:
    sys.exit(f"ASC_KEY_P8 is too short ({len(der)} bytes) - probably copied incompletely.")

lines = [body[i:i + 64] for i in range(0, len(body), 64)]
print("-----BEGIN PRIVATE KEY-----")
print("\n".join(lines))
print("-----END PRIVATE KEY-----")
