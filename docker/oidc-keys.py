#!/opt/kadi/venv/bin/python
"""Manage the RSA keys Kadi signs OIDC ID tokens with.

    kadi-oidc-keys ensure            Generate the default key if it is missing, then check
                                     every configured key (run by the entrypoint).
    kadi-oidc-keys generate <path>   Generate a new key, e.g. for rotation.

The configured keys come from OIDC_SIGNING_KEYS in the Kadi config file, so this script
and Kadi always agree on them.
"""

import os
import runpy
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

# Must match the default in config/kadi.py.
DEFAULT_KEY = "/opt/kadi/oidc/signing-key.pem"
KEY_SIZE = 3072


def generate(path):
    if os.path.exists(path):
        sys.exit(f"{path} already exists, refusing to overwrite it.")

    key = rsa.generate_private_key(public_exponent=65537, key_size=KEY_SIZE)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )

    # O_EXCL: never clobber a key another process created in the meantime.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(pem)

    print(f"Generated a new {KEY_SIZE} bit RSA OIDC signing key at {path}.")


def check(path):
    """Kadi only fails on a broken key while issuing a token (HTTP 500, after the
    authorization code has been consumed), so catch the problem at startup instead."""
    try:
        with open(path, "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
    except (OSError, ValueError, TypeError) as e:
        return f"{path}: cannot be loaded ({e})"

    if not isinstance(key, rsa.RSAPrivateKey):
        return f"{path}: Kadi only supports RSA keys, not {type(key).__name__}"

    if key.key_size < 2048:
        return f"{path}: RSA key has {key.key_size} bits, at least 2048 are required"

    return None


def configured_keys():
    config = runpy.run_path(os.environ["KADI_CONFIG_FILE"])
    return config.get("OIDC_SIGNING_KEYS", [])


def main(args):
    if args[:1] == ["generate"] and len(args) == 2:
        generate(args[1])
        return

    if args != ["ensure"]:
        sys.exit(__doc__)

    keys = configured_keys()

    if not keys:
        print("OIDC provider disabled (KADI_OIDC_PROVIDER is not true).")
        return

    if keys == [DEFAULT_KEY] and not os.path.exists(DEFAULT_KEY):
        generate(DEFAULT_KEY)

    errors = [error for error in map(check, keys) if error]

    if errors:
        sys.exit(
            "Invalid OIDC signing keys (check KADI_OIDC_SIGNING_KEYS):\n"
            + "\n".join(f"  - {error}" for error in errors)
        )

    print(f"OIDC provider enabled, ID tokens are signed with {keys[0]}.")


if __name__ == "__main__":
    main(sys.argv[1:])
