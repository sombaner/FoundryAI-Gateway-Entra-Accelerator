#!/usr/bin/env python3
"""
Decode (not verify) an Entra ID access token's claims so you can confirm
they match what the APIM validate-azure-ad-token policy expects, without
having to paste the raw token anywhere.

This does NOT verify the signature — it just base64-decodes the payload
locally, for diagnostic purposes only.

Usage:
    python3 infra/scripts/decode-token.py "<paste-token-here>"
    # or, to avoid it landing in shell history:
    python3 infra/scripts/decode-token.py --stdin
    (then paste the token and press Ctrl-D)
"""
import base64
import json
import os
from pathlib import Path
import sys


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Missing required environment variable: {name} (see infra/azure.env.example)")
    return value


_load_env_file(Path(__file__).resolve().parent.parent / "azure.env")

EXPECTED = {
    "tid": _require_env("AZURE_TENANT_ID"),
    "aud": f"api://{_require_env('GATEWAY_API_CLIENT_ID')}",
    "appid_or_azp": _require_env("COWORK_CLIENT_ID"),
    "scp_contains": os.environ.get("GATEWAY_SCOPE_NAME", "Inference.Invoke"),
}


def b64url_decode(segment: str) -> bytes:
    padded = segment + "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(padded)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--stdin":
        token = sys.stdin.read().strip()
    elif len(sys.argv) > 1:
        token = sys.argv[1].strip()
    else:
        print("Usage: python3 decode-token.py <token>  (or --stdin)", file=sys.stderr)
        sys.exit(1)

    parts = token.split(".")
    if len(parts) != 3:
        print("Doesn't look like a JWT (expected 3 dot-separated parts).", file=sys.stderr)
        sys.exit(1)

    header = json.loads(b64url_decode(parts[0]))
    payload = json.loads(b64url_decode(parts[1]))

    print("=== Header ===")
    print(json.dumps(header, indent=2))

    print("\n=== Key claims ===")
    interesting = ["aud", "iss", "tid", "appid", "azp", "scp", "roles", "ver", "upn", "oid"]
    for k in interesting:
        if k in payload:
            print(f"{k:8s}: {payload[k]}")

    print("\n=== Expected values (for this deployment) ===")
    for k, v in EXPECTED.items():
        print(f"{k:14s}: {v}")

    print("\n=== Checks ===")
    aud_ok = payload.get("aud") == EXPECTED["aud"]
    tid_ok = payload.get("tid") == EXPECTED["tid"]
    client_id = payload.get("azp") or payload.get("appid")
    client_ok = client_id == EXPECTED["appid_or_azp"]
    scp = payload.get("scp", "")
    scp_ok = EXPECTED["scp_contains"] in scp.split(" ") if scp else False
    ver_ok = payload.get("ver") == "2.0"

    print(f"aud matches gateway-api-client-id : {'OK' if aud_ok else 'MISMATCH -> ' + str(payload.get('aud'))}")
    print(f"tid matches entra-tenant-id       : {'OK' if tid_ok else 'MISMATCH -> ' + str(payload.get('tid'))}")
    print(f"azp/appid matches cowork-client-id: {'OK' if client_ok else 'MISMATCH -> ' + str(client_id)}")
    print(f"scp contains Inference.Invoke     : {'OK' if scp_ok else 'MISMATCH -> ' + str(scp)}")
    print(f"token version is v2.0             : {'OK' if ver_ok else 'WARNING -> ver=' + str(payload.get('ver'))}")


if __name__ == "__main__":
    main()
