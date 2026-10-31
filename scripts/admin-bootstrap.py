#!/usr/bin/env python3
"""Idempotently provision the private operator OIDC client; never log credentials."""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from admin_config import CALLBACK, CLIENT_ID, IDENTITY_PUBLIC_URL


def main():
    identity = os.environ["IDENTITY_URL"].rstrip("/")

    def call(path, data=None, token=None, method=None):
        headers = {}
        if isinstance(data, (dict, list)):
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        elif data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(identity + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read()
            return json.loads(body) if body else None

    for attempt in range(60):
        try:
            token = call(
                "/realms/master/protocol/openid-connect/token",
                urllib.parse.urlencode(
                    {
                        "client_id": "admin-cli",
                        "grant_type": "password",
                        "username": "admin",
                        "password": os.environ["ADMIN_PASSWORD"],
                    }
                ).encode(),
            )["access_token"]
            break
        except urllib.error.HTTPError as error:
            if error.code < 500:
                raise SystemExit(f"Operator bootstrap rejected by identity provider (HTTP {error.code}).") from None
        except (urllib.error.URLError, TimeoutError):
            pass
        if attempt == 59:
            raise SystemExit("Identity provider unavailable; operator bootstrap was not completed.")
        time.sleep(2)

    realm = call("/admin/realms/master", token=token)
    attributes = {**realm.get("attributes", {}), "frontendUrl": IDENTITY_PUBLIC_URL}
    call(
        "/admin/realms/master",
        {"attributes": attributes, "bruteForceProtected": True},
        token,
        "PUT",
    )
    # Changing the private master issuer invalidates the bootstrap token's issuer.
    token = call(
        "/realms/master/protocol/openid-connect/token",
        urllib.parse.urlencode(
            {
                "client_id": "admin-cli",
                "grant_type": "password",
                "username": "admin",
                "password": os.environ["ADMIN_PASSWORD"],
            }
        ).encode(),
    )["access_token"]
    definition = {
        "clientId": CLIENT_ID,
        "name": "Nephos administration",
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": False,
        "secret": os.environ["ADMIN_OIDC_CLIENT_SECRET"],
        "standardFlowEnabled": True,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": False,
        "fullScopeAllowed": False,
        "redirectUris": [CALLBACK],
        "webOrigins": [],
        "defaultClientScopes": ["profile", "roles"],
        "attributes": {"pkce.code.challenge.method": "S256"},
        "protocolMappers": [
            {
                "name": "operator-roles",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-usermodel-realm-role-mapper",
                "config": {
                    "claim.name": "realm_access.roles",
                    "jsonType.label": "String",
                    "multivalued": "true",
                    "id.token.claim": "true",
                    "access.token.claim": "true",
                    "userinfo.token.claim": "false",
                },
            }
        ],
    }
    path = "/admin/realms/master/clients"
    clients = call(path + "?clientId=" + CLIENT_ID, token=token)
    if clients:
        client_id = clients[0]["id"]
        call(path + "/" + client_id, definition, token, "PUT")
    else:
        call(path, definition, token)
        client_id = call(path + "?clientId=" + CLIENT_ID, token=token)[0]["id"]
    role = call("/admin/realms/master/roles/admin", token=token)
    call(path + "/" + client_id + "/scope-mappings/realm", [role], token)
    print("Private operator OIDC client configured; public media realm and user credentials unchanged.")


if __name__ == "__main__":
    main()
