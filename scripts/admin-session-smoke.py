#!/usr/bin/env python3
"""Fault-inject only the explicitly named development administration containers."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import subprocess
import urllib.parse
import smoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console-container", required=True)
    parser.add_argument("--session-container", required=True)
    parser.add_argument("--base-url", default="http://localhost:18082")
    parser.add_argument("--skip-store-outage", action="store_true", help="Do not pause a shared session store.")
    args = parser.parse_args()
    admin = smoke.AdminSession(args.base_url)
    jar = next(handler.cookiejar for handler in admin.opener.handlers if hasattr(handler, "cookiejar"))
    cookie = next(cookie.value for cookie in jar if cookie.name == "nephos_admin")

    def alter(field):
        program = """
import sys,time
from admin_web import app,store
key = 'nephos:admin:' + sys.stdin.read()
data = app.session_interface.serializer.decode(store.get(key))
if sys.argv[1] == 'refresh':
    data['token']['expires_at'] = time.time() - 1
else:
    data['deadline'] = time.time() - 1
store.set(key, app.session_interface.serializer.encode(data), ex=store.ttl(key))
"""
        subprocess.run(
            ["docker", "exec", "-i", args.console_container, "python", "-c", program, field],
            input=cookie,
            text=True,
            check=True,
            capture_output=True,
        )

    def signed_in():
        return "<button>Sign out</button>" in admin.request()

    try:
        alter("refresh")
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(
                pool.map(
                    lambda _: smoke.request(args.base_url + "/", headers={"Cookie": "nephos_admin=" + cookie}),
                    range(4),
                )
            )
        assert all("<button>Sign out</button>" in page for page in results), "Concurrent token refresh failed."
        subprocess.run(["docker", "restart", args.console_container], check=True, capture_output=True)
        smoke.wait("administration session survives console restart", signed_in)
        if not args.skip_store_outage:
            subprocess.run(["docker", "pause", args.session_container], check=True, capture_output=True)
            try:
                page = admin.request(expected=503)
                assert "session store is unavailable" in page
            finally:
                subprocess.run(["docker", "unpause", args.session_container], check=True, capture_output=True)
            smoke.wait("session service recovers without accepting an unauthenticated request", signed_in)
        alter("expire")
        assert "administrator session has ended" in admin.request(expected=401)
        assert "Sign in to Nephos" in admin.request()
        print("PASS: concurrent real token refresh, console restart and absolute session expiry")
    finally:
        if signed_in():
            admin.close()

    admin = smoke.AdminSession(args.base_url)
    jar = next(handler.cookiejar for handler in admin.opener.handlers if hasattr(handler, "cookiejar"))
    cookie = next(cookie.value for cookie in jar if cookie.name == "nephos_admin")
    headers = {"Cookie": "nephos_admin=" + cookie, "Origin": args.base_url}
    try:
        alter("refresh")
        with ThreadPoolExecutor(max_workers=4) as pool:
            reads = [
                pool.submit(smoke.request, args.base_url + "/", headers=headers, expected=(200, 401)) for _ in range(3)
            ]
            logout = pool.submit(
                smoke.request,
                args.base_url + "/logout",
                headers={**headers, "Content-Type": "application/x-www-form-urlencoded"},
                data=urllib.parse.urlencode({"csrf": admin.csrf}).encode(),
            )
            logout.result()
            for result in reads:
                result.result()
        assert "Sign in to Nephos" in smoke.request(args.base_url + "/", headers=headers)
        print("PASS: in-flight refresh/read requests cannot resurrect a logged-out session")
    finally:
        if signed_in():
            admin.close()


if __name__ == "__main__":
    main()
