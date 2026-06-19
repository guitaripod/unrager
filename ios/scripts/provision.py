#!/usr/bin/env python3
"""Mint an ad-hoc provisioning profile for unrager on a registered device.

Self-contained App Store Connect client (ES256 JWT). Registers the device,
ensures the `com.guitaripod.unrager` App ID exists, and creates an
IOS_APP_ADHOC profile bound to the team's distribution certificate (whose
private key must be in your keychain) and the device UDID. Writes the
.mobileprovision into ~/Library/MobileDevice/Provisioning Profiles/.

Env (or ~/.config/midgar/credentials.env):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH, APPLE_TEAM_ID
Args:
  --udid UDID            device to authorize (default: the connected device)
  --serial SERIAL        distribution cert serial to match your local key
  --name "iPhone Air"    device display name
"""
import argparse
import base64
import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE = "com.guitaripod.unrager"
PROFILE_NAME = "Unrager AdHoc"


def env(key):
    val = os.environ.get(key)
    if val:
        return val
    path = os.path.expanduser("~/.config/midgar/credentials.env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line.startswith("export "):
                line = line[len("export "):]
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    return None


def token():
    key_path = os.path.expanduser(env("ASC_PRIVATE_KEY_PATH"))
    now = int(time.time())
    payload = {"iss": env("ASC_ISSUER_ID"), "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, open(key_path).read(), algorithm="ES256",
                      headers={"kid": env("ASC_KEY_ID")})


def api(method, path, payload=None):
    r = requests.request(method, BASE + path,
                         headers={"Authorization": f"Bearer {token()}",
                                  "Content-Type": "application/json"},
                         json=payload, timeout=60)
    if r.status_code >= 400:
        print(f"ERROR {r.status_code} {method} {path}\n{r.text[:2000]}", file=sys.stderr)
        r.raise_for_status()
    return r.json() if r.text else {}


def paged(path):
    out, url = [], BASE + path
    while url:
        r = requests.get(url, headers={"Authorization": f"Bearer {token()}"}, timeout=60)
        r.raise_for_status()
        j = r.json()
        out += j.get("data", [])
        url = j.get("links", {}).get("next")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--serial", required=True, help="distribution cert serial matching your local key")
    ap.add_argument("--name", default="iPhone")
    args = ap.parse_args()
    team = env("APPLE_TEAM_ID")

    dev = next((d for d in paged("/v1/devices")
                if d["attributes"].get("udid", "").lower() == args.udid.lower()), None)
    if not dev:
        dev = api("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {
            "name": args.name, "platform": "IOS", "udid": args.udid}}})["data"]
    print("device", dev["id"])

    bid = next((b for b in paged("/v1/bundleIds")
                if b["attributes"].get("identifier") == BUNDLE), None)
    if not bid:
        bid = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE, "name": "Unrager", "platform": "IOS", "seedId": team}}})["data"]
    print("bundleId", bid["id"])

    certs = [c for c in paged("/v1/certificates")
             if c["attributes"].get("certificateType") in ("IOS_DISTRIBUTION", "DISTRIBUTION")
             and c["attributes"].get("serialNumber") == args.serial]
    if not certs:
        print("no distribution cert matching serial", args.serial, file=sys.stderr)
        sys.exit(1)
    cert_id = certs[0]["id"]
    print("cert", cert_id, certs[0]["attributes"].get("displayName"))

    for p in paged("/v1/profiles"):
        if p["attributes"].get("name") == PROFILE_NAME:
            api("DELETE", f"/v1/profiles/{p['id']}")

    prof = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_ADHOC"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bid["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            "devices": {"data": [{"type": "devices", "id": dev["id"]}]}}}})["data"]
    uuid = prof["attributes"]["uuid"]
    dest = os.path.expanduser(f"~/Library/MobileDevice/Provisioning Profiles/{uuid}.mobileprovision")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
    print(f"profile '{PROFILE_NAME}' → {dest}")


if __name__ == "__main__":
    main()
