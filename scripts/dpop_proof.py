"""DPoP proof construction for real-service qualification clients."""

import base64
import hashlib
import json
import time
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))


def jwk(key):
    point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return {"kty": "EC", "crv": "P-256", "x": b64(point[1:33]), "y": b64(point[33:])}


def thumbprint(key):
    return b64(hashlib.sha256(json.dumps(jwk(key), sort_keys=True, separators=(",", ":")).encode()).digest())


def proof(key, url, *, method="POST", issued=None, identifier=None):
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": jwk(key)}
    body = {
        "jti": identifier or str(uuid.uuid4()),
        "htm": method,
        "htu": url,
        "iat": int(time.time()) if issued is None else issued,
    }
    text = ".".join(b64(json.dumps(part, separators=(",", ":")).encode()) for part in (header, body))
    r, s = utils.decode_dss_signature(key.sign(text.encode(), ec.ECDSA(hashes.SHA256())))
    return text + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
