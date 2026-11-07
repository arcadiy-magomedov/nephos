#!/usr/bin/env python3
"""Generate a throwaway localhost CA and edge certificate, never disable TLS verification."""

import os
from pathlib import Path
import subprocess
import ssl


def main():
    root = Path(__file__).resolve().parents[1] / "artifacts" / "admin-tls"
    root.mkdir(parents=True, mode=0o700, exist_ok=False)

    def openssl(*args):
        subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "2",
        "-subj",
        "/CN=Nephos disposable qualification CA",
        "-keyout",
        str(root / "ca.key"),
        "-out",
        str(root / "ca.crt"),
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign",
    )
    openssl(
        "req",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-subj",
        "/CN=localhost",
        "-addext",
        "subjectAltName=DNS:localhost,IP:127.0.0.1",
        "-addext",
        "extendedKeyUsage=serverAuth",
        "-keyout",
        str(root / "tls.key"),
        "-out",
        str(root / "tls.csr"),
    )
    openssl(
        "x509",
        "-req",
        "-in",
        str(root / "tls.csr"),
        "-CA",
        str(root / "ca.crt"),
        "-CAkey",
        str(root / "ca.key"),
        "-CAcreateserial",
        "-days",
        "2",
        "-copy_extensions",
        "copy",
        "-out",
        str(root / "tls.crt"),
    )
    for name in ("ca.key", "tls.key"):
        os.chmod(root / name, 0o600)
    default_ca = ssl.get_default_verify_paths().openssl_cafile
    context = ssl.create_default_context(cafile=default_ca if default_ca and Path(default_ca).is_file() else None)
    if not context.get_ca_certs():
        raise RuntimeError("System certificate authorities unavailable; cannot construct qualification trust store.")
    with (root / "trust.pem").open("w") as output:
        for certificate in context.get_ca_certs(binary_form=True):
            output.write(ssl.DER_cert_to_PEM_cert(certificate))
        output.write((root / "ca.crt").read_text())
    print("Created isolated test CA and localhost certificate.")


if __name__ == "__main__":
    main()
