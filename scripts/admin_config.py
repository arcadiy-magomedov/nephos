"""Explicit front-channel origins; internal provider traffic stays on the service network."""

import ipaddress
import os
from urllib.parse import urlsplit


def origin(value):
    parsed = urlsplit(value)
    port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or "?" in value
        or "#" in value
        or any(char.isspace() or not char.isprintable() for char in value)
        or not 1 <= port <= 65535
    ):
        raise ValueError("Administration URLs must be explicit HTTP(S) origins without credentials or paths.")
    if parsed.scheme == "http":
        try:
            loopback = ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            loopback = parsed.hostname == "localhost"
        if not loopback:
            raise ValueError("Unencrypted administration is allowed only on loopback.")
    return parsed.scheme + "://" + parsed.netloc.lower()


PUBLIC_URL = origin(os.environ.get("ADMIN_PUBLIC_URL", "http://localhost:18082"))
IDENTITY_PUBLIC_URL = origin(os.environ.get("ADMIN_IDENTITY_PUBLIC_URL", "http://localhost:18081"))
ISSUER = IDENTITY_PUBLIC_URL + "/realms/master"
CLIENT_ID = "nephos-administration"
CALLBACK = PUBLIC_URL + "/oauth/callback"
