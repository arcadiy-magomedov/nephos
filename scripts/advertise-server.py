#!/usr/bin/env python3
"""Publish a Nephos HTTPS address using the host's Bonjour or Avahi daemon."""

import argparse
import ipaddress
import os
import shutil
import sys
import urllib.parse


def advertisement(address, name, platform):
    if not name.strip() or len(name.encode()) > 63 or not name.isprintable():
        raise ValueError("Service name must be printable and contain 1-63 UTF-8 bytes.")
    if any(char.isspace() or not char.isprintable() for char in address) or "?" in address or "#" in address:
        raise ValueError("Server URL cannot contain whitespace, query parameters or a fragment.")
    parsed = urllib.parse.urlsplit(address)
    host = parsed.hostname
    port = parsed.port if parsed.port is not None else 443
    if parsed.scheme != "https" or not host or parsed.username is not None or parsed.password is not None:
        raise ValueError("Publish an HTTPS server URL without credentials.")
    hostname = host.lower().rstrip(".")
    if hostname == "localhost" or hostname.endswith(".localhost"):
        raise ValueError("Publish a hostname reachable by other devices, not localhost.")
    try:
        ip = ipaddress.ip_address(hostname)
    except ValueError:
        ip = None
    if ip is not None and (ip.is_loopback or ip.is_unspecified):
        raise ValueError("Loopback and unspecified addresses cannot be advertised.")
    if not 1 <= port <= 65535:
        raise ValueError("Server port must be between 1 and 65535.")
    hostpart = f"[{host}]" if ":" in host else host
    netloc = hostpart + (f":{parsed.port}" if parsed.port is not None else "")
    url = urllib.parse.urlunsplit(("https", netloc, parsed.path.rstrip("/"), "", ""))
    if len(url.encode()) > 251:
        raise ValueError("Server URL is too long for one DNS-SD TXT entry (251 UTF-8 bytes).")
    if platform == "darwin":
        return ["dns-sd", "-R", name, "_nephos._tcp", "local.", str(port), "v=1", "url=" + url]
    if platform.startswith("linux"):
        return ["avahi-publish-service", name, "_nephos._tcp", str(port), "v=1", "url=" + url]
    raise ValueError("Host advertising currently supports macOS (Bonjour) and Linux (Avahi).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Canonical HTTPS API base URL, matching its TLS certificate.")
    parser.add_argument("--name", default="Nephos", help="Public LAN service name, not a credential or user name.")
    args = parser.parse_args()
    try:
        command = advertisement(args.url, args.name, sys.platform)
    except ValueError as error:
        parser.error(str(error))
    executable = shutil.which(command[0])
    if executable is None:
        parser.error("Host Bonjour/Avahi publisher is missing. On Linux install avahi-daemon and avahi-utils.")
    print(
        f"Publishing {args.name} as {command[-1][4:]} on the local network. Stop this process to withdraw it.",
        flush=True,
    )
    os.execv(executable, command)


if __name__ == "__main__":
    main()
