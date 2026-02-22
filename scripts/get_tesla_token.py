#!/usr/bin/env python3
import argparse
import getpass
import json
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REGION_AUDIENCE = {
    "na": "https://fleet-api.prd.na.vn.cloud.tesla.com",
    "eu": "https://fleet-api.prd.eu.vn.cloud.tesla.com",
}
REGION_ORDER = ["eu", "na"]
TOKEN_HOST = "fleet-auth.prd.vn.cloud.tesla.com"
AUTH_HOST = "auth.tesla.com"
DEFAULT_SCOPE = "openid offline_access vehicle_device_data"
KEY_REL_PATH = ".well-known/appspecific/com.tesla.3p.public-key.pem"


class UserCancelled(Exception):
    pass


def mask_token(token: str) -> str:
    if len(token) <= 8:
        return "*" * len(token)
    return token[:4] + "..." + token[-4:]


def prompt_text(label: str, default: str = "", secret: bool = False, required: bool = True) -> str:
    shown_default = f" [{default}]" if default else ""
    while True:
        try:
            if secret:
                value = getpass.getpass(f"{label}{shown_default}: ")
            else:
                value = input(f"{label}{shown_default}: ")
        except (KeyboardInterrupt, EOFError):
            raise UserCancelled()
        value = value.strip()
        if value:
            return value
        if default:
            return default
        if not required:
            return ""
        print("This field is required.")


def prompt_yes_no(label: str, default: bool) -> bool:
    suffix = "Y/n" if default else "y/N"
    while True:
        try:
            value = input(f"{label} [{suffix}]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            raise UserCancelled()
        if value == "":
            return default
        if value in {"y", "yes"}:
            return True
        if value in {"n", "no"}:
            return False
        print("Please answer yes or no.")


def post_form(url: str, form: dict) -> tuple[int, dict, str]:
    body = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=body,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}, ""
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        data = {}
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            pass
        return err.code, data, raw[:800]


def post_json(url: str, bearer_token: str, payload: dict) -> tuple[int, dict, str]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {bearer_token}",
            "Accept": "application/json",
        },
        data=body,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw) if raw else {}
            return resp.status, data, ""
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        data = {}
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            pass
        return err.code, data, raw[:800]


def get_json(url: str, bearer_token: str) -> tuple[int, dict, str]:
    req = urllib.request.Request(
        url=url,
        method="GET",
        headers={
            "Authorization": f"Bearer {bearer_token}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw) if raw else {}
            return resp.status, data, ""
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        data = {}
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            pass
        return err.code, data, raw[:800]


def generate_keypair(private_key: Path, public_key: Path) -> None:
    private_key.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(private_key)],
        check=True,
    )
    subprocess.run(["openssl", "ec", "-in", str(private_key), "-pubout", "-out", str(public_key)], check=True)


def build_auth_url(client_id: str, redirect_uri: str, scope: str, state: str) -> str:
    query = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": scope,
            "state": state,
        }
    )
    return f"https://{AUTH_HOST}/oauth2/v3/authorize?{query}"


def run_oauth_browser_flow(client_id: str, redirect_uri: str, scope: str, timeout_seconds: int, no_open: bool) -> tuple[str, str]:
    parsed_redirect = urllib.parse.urlparse(redirect_uri)
    host = parsed_redirect.hostname
    port = parsed_redirect.port
    path = parsed_redirect.path or "/"
    if parsed_redirect.scheme != "http" or not host or not port:
        return "", "redirect_uri must be http://localhost:3000/callback style for local capture"

    state = secrets.token_urlsafe(16)
    auth_url = build_auth_url(client_id, redirect_uri, scope, state)
    result = {"code": None, "state": None, "error": None}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args):
            return

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != path:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not found")
                return

            qs = urllib.parse.parse_qs(parsed.query)
            result["code"] = (qs.get("code") or [None])[0]
            result["state"] = (qs.get("state") or [None])[0]
            result["error"] = (qs.get("error") or [None])[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                b"<html><body><h3>Tesla auth received.</h3><p>You can close this tab and return to Terminal.</p></body></html>"
            )

    try:
        server = HTTPServer((host, port), Handler)
    except OSError as err:
        return "", f"Cannot bind callback server on {host}:{port}: {err}"

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    print("\nOpen this URL to authorize:")
    print(auth_url)
    if not no_open:
        webbrowser.open(auth_url)

    started = time.time()
    try:
        while time.time() - started < timeout_seconds:
            if result["code"] or result["error"]:
                break
            time.sleep(0.2)
    finally:
        server.shutdown()
        server.server_close()

    if result["error"]:
        return "", f"OAuth error from callback: {result['error']}"
    if not result["code"]:
        return "", "Timed out waiting for callback code."
    if result["state"] != state:
        return "", "State mismatch; aborting for safety."
    return result["code"], ""


def parse_domain(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if "://" in value:
        parsed = urllib.parse.urlparse(value)
        return (parsed.hostname or "").strip().lower()
    if "/" in value:
        value = value.split("/", 1)[0]
    return value.strip().lower()


def normalize_region_list(value: str) -> list[str]:
    out = []
    for item in value.split(","):
        region = item.strip().lower()
        if region in REGION_AUDIENCE and region not in out:
            out.append(region)
    return out


def build_partner_token(token_host: str, client_id: str, client_secret: str, audience: str) -> tuple[str, str]:
    status, data, raw_err = post_form(
        f"https://{token_host}/oauth2/v3/token",
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": "openid vehicle_device_data",
            "audience": audience,
        },
    )
    if status < 200 or status >= 300:
        reason = data.get("error_description") or data.get("error") or raw_err
        return "", f"partner token failed ({status}): {reason}"
    token = data.get("access_token", "")
    if not token:
        return "", f"partner token missing access_token: {json.dumps(data)}"
    return token, ""


def register_partner_account(audience: str, partner_token: str, domain: str, key_url: str) -> tuple[bool, str]:
    endpoint = f"{audience}/api/1/partner_accounts"

    status, payload, raw_err = post_json(endpoint, partner_token, {"domain": domain})
    if 200 <= status < 300:
        return True, "registered"

    status2, payload2, raw_err2 = post_json(endpoint, partner_token, {"domain": domain, "public_key_url": key_url})
    if 200 <= status2 < 300:
        return True, "registered"

    merged = payload2 or payload or {}
    err_text = ""
    if isinstance(merged, dict):
        err_text = str(merged.get("error") or merged.get("message") or "").strip()
    if not err_text:
        err_text = (raw_err2 or raw_err or "").strip()

    low = err_text.lower()
    if "already" in low and "register" in low:
        return True, "already_registered"

    return False, f"HTTP {status2}: {err_text}" if err_text else f"HTTP {status2}"


def verify_public_key(audience: str, partner_token: str, domain: str) -> tuple[bool, str]:
    url = f"{audience}/api/1/partner_accounts/public_key?domain={urllib.parse.quote(domain)}"
    status, payload, raw_err = get_json(url, partner_token)
    if 200 <= status < 300:
        return True, ""
    reason = payload.get("error") if isinstance(payload, dict) else ""
    if not reason:
        reason = raw_err
    return False, f"HTTP {status}: {reason}"


def detect_user_region_with_token(access_token: str) -> tuple[str, str]:
    for region in REGION_ORDER:
        audience = REGION_AUDIENCE[region]
        status, payload, _raw_err = get_json(f"{audience}/api/1/users/region", access_token)
        if 200 <= status < 300:
            response = payload.get("response") if isinstance(payload, dict) else None
            fleet_url = ""
            if isinstance(response, dict):
                fleet_url = str(response.get("fleet_api_base_url") or "").strip()
            if fleet_url:
                return fleet_url.rstrip("/"), ""
            return audience, ""
    return "", "Could not determine user region from /users/region"


def fetch_vehicle_id(audience: str, access_token: str) -> tuple[str, str]:
    status, payload, raw_err = get_json(f"{audience}/api/1/vehicles", access_token)
    if status < 200 or status >= 300:
        reason = payload.get("error") if isinstance(payload, dict) else ""
        detail = raw_err or ""
        return "", f"HTTP {status}: {reason or detail}".strip()

    response = payload.get("response") if isinstance(payload, dict) else None
    if isinstance(response, list) and response:
        first = response[0]
        vid = first.get("id")
        if vid:
            return str(vid), ""
    return "", "No vehicles returned from /vehicles response."


def interactive_fill(args: argparse.Namespace) -> argparse.Namespace:
    print("Tesla token setup wizard\n")
    print("This will guide you through: partner registration (required once per region) -> OAuth login -> vehicle ID lookup (recommended).\n")

    args.client_id = args.client_id or prompt_text("client_id")
    args.client_secret = args.client_secret or prompt_text("client_secret", secret=True)

    use_default_redirect = prompt_yes_no(
        "Use default redirect URI http://localhost:3000/callback (must match Tesla app settings)",
        True,
    )
    if not use_default_redirect:
        args.redirect_uri = prompt_text("Redirect URI", args.redirect_uri)

    if not args.skip_register:
        run_registration = prompt_yes_no("Run partner registration step now (required once per region)", True)
        args.skip_register = not run_registration

    if not args.skip_register:
        default_regions = ",".join(args.register_regions)
        regions_text = prompt_text(
            "Regions to register (comma-separated: eu,na)",
            default_regions,
        )
        regions = normalize_region_list(regions_text)
        if not regions:
            regions = list(args.register_regions)
        args.register_regions = regions

        args.domain = parse_domain(args.domain or prompt_text("App domain from Tesla allowed_origins (example.com)"))
        args.generate_keys = args.generate_keys or prompt_yes_no("Generate new EC key pair files", True)
        run_key_check = prompt_yes_no("Validate hosted public key URL now", False)
        args.skip_public_key_check = not run_key_check
        if not args.no_open:
            args.no_open = not prompt_yes_no("Open browser automatically", True)

    args.fetch_vehicle_id = args.fetch_vehicle_id or prompt_yes_no("Fetch first vehicle id automatically", True)
    return args


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Tesla Fleet setup helper: partner registration + OAuth token + vehicle id lookup"
    )
    parser.add_argument("--client-id", help="Tesla OAuth client_id")
    parser.add_argument("--client-secret", help="Tesla OAuth client_secret")
    parser.add_argument("--token-host", default=TOKEN_HOST)
    parser.add_argument("--redirect-uri", default="http://localhost:3000/callback")
    parser.add_argument("--scope", default=DEFAULT_SCOPE)
    parser.add_argument("--timeout-seconds", type=int, default=300)

    parser.add_argument("--skip-register", action="store_true", help="Skip partner register flow")
    parser.add_argument("--register-regions", default="eu,na", help="Comma-separated regions to register (eu,na)")
    parser.add_argument("--domain", help="App domain that matches Tesla allowed_origins")
    parser.add_argument("--private-key-file", default=str(Path.home() / ".config/tesla-notifier/private-key.pem"))
    parser.add_argument("--public-key-file", default=str(Path.home() / ".config/tesla-notifier/public-key.pem"))
    parser.add_argument("--generate-keys", action="store_true", help="Generate EC key pair before registration")
    parser.add_argument("--skip-public-key-check", action="store_true", help="Skip HTTPS public-key URL check")

    parser.add_argument("--audience", help="Fleet API URL to force for /vehicles lookup")
    parser.add_argument("--fetch-vehicle-id", action="store_true", help="Fetch first vehicle id after auth")
    parser.add_argument("--no-open", action="store_true", help="Do not auto-open browser")
    parser.add_argument("--print-token", action="store_true", help="Print full access token")
    parser.add_argument("--interactive", action="store_true", help="Prompt for missing values (auto when no args)")

    args = parser.parse_args()
    no_user_args = len(sys.argv) == 1
    interactive = args.interactive or no_user_args

    args.register_regions = normalize_region_list(args.register_regions)
    if not args.register_regions:
        args.register_regions = ["eu", "na"]

    args.domain = parse_domain(args.domain or "")

    try:
        if interactive:
            args = interactive_fill(args)

        if not args.client_id:
            parser.error("--client-id is required")
        if not args.client_secret:
            parser.error("--client-secret is required")

        if not args.skip_register:
            if not args.domain:
                parser.error("--domain is required unless --skip-register is used")

            private_key = Path(args.private_key_file).expanduser()
            public_key = Path(args.public_key_file).expanduser()

            if args.generate_keys or not private_key.exists() or not public_key.exists():
                print("\nGenerating EC key pair...")
                try:
                    generate_keypair(private_key, public_key)
                except Exception as err:
                    print("Failed to generate key pair:", err)
                    return 1
                print("Private key:", private_key)
                print("Public key:", public_key)

            key_url = f"https://{args.domain}/{KEY_REL_PATH}"
            print("\nPublic key must be hosted at:")
            print(key_url)
            if interactive:
                _ = prompt_text(
                    "Press Enter after you uploaded the public key",
                    default="",
                    required=False,
                )

            if not args.skip_public_key_check:
                try:
                    req = urllib.request.Request(
                        key_url,
                        headers={
                            "User-Agent": "Mozilla/5.0",
                            "Accept": "text/plain,*/*;q=0.8",
                        },
                    )
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        content = resp.read().decode("utf-8", errors="replace")
                        if "BEGIN PUBLIC KEY" not in content:
                            print("Public key URL is reachable but not a valid PEM public key.")
                            return 1
                except Exception as err:
                    print("Public key URL check failed:", err)
                    print("Upload the public key first, then rerun. Or rerun with --skip-public-key-check.")
                    return 1

            print("\nRegistering partner account in requested regions...")
            for region in args.register_regions:
                audience = REGION_AUDIENCE[region]
                partner_token, partner_err = build_partner_token(
                    args.token_host,
                    args.client_id,
                    args.client_secret,
                    audience,
                )
                if partner_err:
                    print(f"[{region.upper()}] {partner_err}")
                    return 1

                ok, register_msg = register_partner_account(audience, partner_token, args.domain, key_url)
                if not ok:
                    print(f"[{region.upper()}] Partner registration failed: {register_msg}")
                    print("Hint: ensure domain exactly matches your Tesla app allowed_origins root domain.")
                    return 1

                verified, verify_msg = verify_public_key(audience, partner_token, args.domain)
                status = "verified" if verified else f"verify failed ({verify_msg})"
                print(f"[{region.upper()}] registration: {register_msg}; public key: {status}")
    except UserCancelled:
        print("\nCancelled by user.")
        return 130

    print("\nStarting user OAuth authorization code flow...")
    code, oauth_err = run_oauth_browser_flow(
        client_id=args.client_id,
        redirect_uri=args.redirect_uri,
        scope=args.scope,
        timeout_seconds=args.timeout_seconds,
        no_open=args.no_open,
    )
    if oauth_err:
        print(oauth_err)
        return 1

    print("Exchanging authorization code for user token...")

    token_audience = args.audience or REGION_AUDIENCE["eu"]
    status, user_token_resp, raw_err = post_form(
        f"https://{args.token_host}/oauth2/v3/token",
        {
            "grant_type": "authorization_code",
            "client_id": args.client_id,
            "client_secret": args.client_secret,
            "code": code,
            "redirect_uri": args.redirect_uri,
            "audience": token_audience,
        },
    )
    if status < 200 or status >= 300:
        reason = user_token_resp.get("error_description") or user_token_resp.get("error") or raw_err
        print(f"User token exchange failed ({status}): {reason}")
        return 1

    access_token = user_token_resp.get("access_token", "")
    if not access_token:
        print("Token exchange response missing access_token:")
        print(json.dumps(user_token_resp, indent=2))
        return 1

    print("\nToken exchange succeeded.")
    show_full_token = args.print_token
    if interactive and not args.print_token:
        show_full_token = prompt_yes_no("Show full access_token now", True)
    if show_full_token:
        print("access_token:", access_token)
    else:
        print("access_token (masked):", mask_token(access_token))

    resolved_audience = args.audience
    if not resolved_audience:
        resolved_audience, region_err = detect_user_region_with_token(access_token)
        if region_err:
            resolved_audience = REGION_AUDIENCE["eu"]
            print(f"Region auto-detect failed; using default {resolved_audience}. ({region_err})")
        else:
            print("Detected Fleet API region:", resolved_audience)

    print("\nPut this in config.json:")
    print('"forwardingGateMode": "tesla_fleet",')
    print('"forwardingGateFailOpen": false,')
    print('"teslaFleetBearerToken": "<paste access_token>",')

    if args.fetch_vehicle_id or interactive:
        vid, fetch_err = fetch_vehicle_id(resolved_audience, access_token)
        if vid:
            print(f'"teslaFleetVehicleDataURL": "{resolved_audience}/api/1/vehicles/{vid}/vehicle_data"')
        else:
            print("Could not auto-detect vehicle id.")
            if fetch_err:
                print("Reason:", fetch_err)
            print("If reason contains HTTP 412, registration is still missing in that region.")
            print('"teslaFleetVehicleDataURL": "https://<fleet-host>/api/1/vehicles/<vehicle_id>/vehicle_data"')

    refresh_token = user_token_resp.get("refresh_token")
    if refresh_token:
        print("\nrefresh_token returned (store securely if you need token refresh).")

    print("\nNotes:")
    print("- Redirect URI/port are still required in this script because OAuth must capture your callback code locally.")
    print("- They must match the redirect configured in Tesla Developer Portal.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
