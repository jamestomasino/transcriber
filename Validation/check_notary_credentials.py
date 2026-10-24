#!/usr/bin/env python3
"""Read-only Apple Notary API authentication check, usable from Linux or macOS.

Developer tool only; requires PyJWT and cryptography. The private key and the
two-minute bearer token stay in memory and are never printed or written.
"""

import argparse
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from uuid import UUID


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True, type=Path, help="Original .p8 file")
    parser.add_argument("--key-id", required=True, help="API key ID, not Team ID")
    parser.add_argument("--issuer", required=True, help="Team API key issuer UUID")
    args = parser.parse_args()
    try:
        import jwt
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
    except ImportError:
        parser.exit(2, "Requires PyJWT and cryptography in your Python environment.\n")

    try:
        issuer = str(UUID(args.issuer.strip()))
        key = serialization.load_pem_private_key(args.key.expanduser().read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
            parser.exit(2, "The key must be an unencrypted P-256 private key.\n")
    except (OSError, ValueError, TypeError):
        parser.exit(2, "Could not read the PEM private key or parse the issuer UUID.\n")

    now = int(time.time())
    token = jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 120, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": args.key_id.strip(), "typ": "JWT"},
    )
    request = urllib.request.Request(
        "https://appstoreconnect.apple.com/notary/v2/submissions",
        headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
        method="GET",
    )

    # Never forward the bearer token to a redirect destination.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            if response.status != 200:
                print(f"Unexpected Apple response: HTTP {response.status}.", file=sys.stderr)
                return 1
            print("HTTP 200: Apple Notary API authentication succeeded. No software was submitted.")
            return 0
    except urllib.error.HTTPError as error:
        print(f"HTTP {error.code}: Apple rejected the request.", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError):
        print("Network/TLS error or timeout contacting Apple; authentication is unconfirmed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
