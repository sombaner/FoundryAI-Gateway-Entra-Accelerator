#!/usr/bin/env python3
"""
Get a Claude Governance gateway access token via Entra ID browser PKCE flow,
then optionally use it to call the gateway directly (POST /v1/messages or
GET /v1/models).

Run this yourself interactively. It opens an Entra sign-in in the system browser
and receives the response on an ephemeral 127.0.0.1 loopback port.

Usage:
    python3 get-gateway-token.py                # just print the token
    python3 get-gateway-token.py --copy          # also copy the raw token to the clipboard
    python3 get-gateway-token.py --credential-helper # print only a cached token for Claude Desktop
    python3 get-gateway-token.py --no-interactive --no-print-token --test-models
    python3 get-gateway-token.py --test-messages # also POST a test message
    python3 get-gateway-token.py --test-models   # also GET /v1/models

Requires: pip install msal msal-extensions requests
"""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import parse_qs, urlparse
import webbrowser

import msal
import requests
from msal_extensions import KeychainPersistence, PersistedTokenCache


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

TENANT_ID = _require_env("AZURE_TENANT_ID")
COWORK_CLIENT_ID = _require_env("COWORK_CLIENT_ID")  # Claude-Cowork-Client (public client)
GATEWAY_API_CLIENT_ID = _require_env("GATEWAY_API_CLIENT_ID")  # AI-Gateway-API (resource app)
SCOPE = f"api://{GATEWAY_API_CLIENT_ID}/{os.environ.get('GATEWAY_SCOPE_NAME', 'Inference.Invoke')}"
GATEWAY_URL = _require_env("GATEWAY_URL")
# Any of these are accepted by the gateway allowlist (see infra/main.bicepparam).
APPROVED_MODELS = [m.strip() for m in _require_env("APPROVED_MODELS").split(",") if m.strip()]
DEFAULT_MODEL = APPROVED_MODELS[0]
TOKEN_CACHE_SERVICE = "Claude Governance Gateway"
TOKEN_CACHE_ACCOUNT = COWORK_CLIENT_ID
CALLBACK_PATH = "/callback"
INTERACTIVE_TIMEOUT_SECONDS = 300


def create_token_cache() -> PersistedTokenCache:
    persistence = KeychainPersistence(
        TOKEN_CACHE_SERVICE,
        TOKEN_CACHE_ACCOUNT,
    )
    return PersistedTokenCache(persistence)


def receive_browser_response(app: msal.PublicClientApplication) -> dict:
    auth_response: dict[str, str] = {}

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            parsed_url = urlparse(self.path)
            if parsed_url.path != CALLBACK_PATH:
                self.send_error(404)
                return

            auth_response.update(
                {
                    key: values[0]
                    for key, values in parse_qs(parsed_url.query).items()
                    if values
                }
            )
            message = b"Sign-in response received. You can close this window."
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)

        def log_message(self, format: str, *args: object) -> None:
            return

    with HTTPServer(("127.0.0.1", 0), CallbackHandler) as callback_server:
        callback_server.timeout = INTERACTIVE_TIMEOUT_SECONDS
        redirect_uri = f"http://127.0.0.1:{callback_server.server_port}{CALLBACK_PATH}"
        flow = app.initiate_auth_code_flow(scopes=[SCOPE], redirect_uri=redirect_uri)
        auth_uri = flow.get("auth_uri")
        if not auth_uri:
            print("Failed to create browser authorization flow:", flow, file=sys.stderr)
            sys.exit(1)

        print(f"Opening Entra sign-in in your browser. Waiting up to {INTERACTIVE_TIMEOUT_SECONDS} seconds...")
        if not webbrowser.open(auth_uri):
            print(f"Open this URL to sign in:\n{auth_uri}")
        callback_server.handle_request()

    if not auth_response:
        print("Timed out waiting for the Entra browser callback.", file=sys.stderr)
        sys.exit(1)

    return app.acquire_token_by_auth_code_flow(flow, auth_response)


def get_token(*, allow_interactive: bool = True, quiet: bool = False) -> str:
    token_cache = create_token_cache()
    app = msal.PublicClientApplication(
        client_id=COWORK_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{TENANT_ID}",
        token_cache=token_cache,
    )

    accounts = app.get_accounts()
    if accounts:
        result = app.acquire_token_silent(scopes=[SCOPE], account=accounts[0])
        if result and "access_token" in result:
            if not quiet:
                print("Acquired gateway token from the secure cache.")
            return result["access_token"]

    if not allow_interactive:
        print(
            "No cached gateway credential. Run get-gateway-token.py once to complete browser sign-in.",
            file=sys.stderr,
        )
        sys.exit(1)

    result = receive_browser_response(app)

    if "access_token" not in result:
        print("Failed to acquire token:", json.dumps(result, indent=2), file=sys.stderr)
        sys.exit(1)

    return result["access_token"]


def call_gateway(token: str, test_messages: bool, test_models: bool, model: str) -> bool:
    headers = {"Authorization": f"Bearer {token}"}
    success = True

    if test_models:
        print("\n=== GET /v1/models ===")
        r = requests.get(f"{GATEWAY_URL}/v1/models", headers=headers, timeout=30)
        print(r.status_code, r.text)
        success = success and r.status_code == 200

    if test_messages:
        print(f"\n=== POST /v1/messages (model={model}) ===")
        body = {
            "model": model,
            "max_tokens": 100,
            "messages": [{"role": "user", "content": "Say hello in one short sentence."}],
        }
        r = requests.post(
            f"{GATEWAY_URL}/v1/messages",
            headers={
                **headers,
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
            },
            json=body,
            timeout=60,
        )
        print(r.status_code, r.text)
        success = success and r.status_code == 200

    return success


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--copy", action="store_true", help="copy the raw token to the clipboard (macOS pbcopy)")
    parser.add_argument(
        "--credential-helper",
        action="store_true",
        help="print only a silently acquired cached token for Claude Desktop",
    )
    parser.add_argument(
        "--no-interactive",
        action="store_true",
        help="use only a silently acquired cached token; fail instead of opening a browser",
    )
    parser.add_argument("--no-print-token", action="store_true", help="do not print the access token")
    parser.add_argument("--test-messages", action="store_true", help="POST a test chat message")
    parser.add_argument("--test-models", action="store_true", help="GET the approved model list")
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        choices=APPROVED_MODELS,
        help=f"Model to use for --test-messages (default: {DEFAULT_MODEL})",
    )
    args = parser.parse_args()

    token = get_token(
        allow_interactive=not (args.credential_helper or args.no_interactive),
        quiet=args.credential_helper or args.no_interactive,
    )
    if args.credential_helper:
        print(token)
    elif not args.no_print_token:
        print("\n=== ACCESS TOKEN (copy this into the Authorization header as 'Bearer <token>') ===")
        print(token)

    if args.test_messages or args.test_models:
        if not call_gateway(token, args.test_messages, args.test_models, args.model):
            sys.exit(1)

    if args.copy:
        # Paste the token verbatim — no "Bearer " prefix, no trailing newline.
        try:
            subprocess.run(["pbcopy"], input=token, text=True, check=True)
            print(f"\n[copied {len(token)} chars to clipboard]")
        except (OSError, subprocess.CalledProcessError) as exc:
            print(f"\n[clipboard copy unavailable: {exc}]", file=sys.stderr)
