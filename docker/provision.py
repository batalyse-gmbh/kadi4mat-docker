#!/opt/kadi/venv/bin/python
"""Register OIDC clients and create access tokens without the web UI. Both are idempotent:
a client or token that already exists (same user, same name) is not created again, and
its secret cannot be shown again.

    kadi-provision oidc-client --owner <user> --name <name> --redirect-uri <uri>...
        Register an OpenID Connect client with the scopes openid, profile and email.
        Prints OIDC_CLIENT_ID, and OIDC_CLIENT_SECRET when it was created. Rerunning
        updates the redirect URIs of an existing client.

    kadi-provision token --user <user> --name <name> --scope "<scope> ..."
        Create a personal access token with exactly these scopes, e.g.
        "record.read record.update". Prints KADI_SERVICE_TOKEN when it was created.
        Refused for sysadmins: a token acts with all rights of its user.

<user> is a user ID or a username. Secrets go to stdout once, everything else to stderr.
"""

import argparse
import sys
from datetime import timedelta
from urllib.parse import urlsplit

from kadi.app import create_app
from kadi.ext.db import db
from kadi.lib.api.models import PersonalToken
from kadi.lib.api.utils import get_access_token_scopes
from kadi.lib.oauth.models import OAuth2ServerClient
from kadi.lib.oidc.core import oidc_enabled
from kadi.lib.utils import utcnow
from kadi.modules.accounts import models as accounts

OIDC_SCOPE = "oidc.email oidc.openid oidc.profile"


def info(message):
    print(message, file=sys.stderr)


def find_user(value):
    if value.isdigit():
        users = set(accounts.User.query.filter_by(id=int(value)))
    else:
        identity_types = (
            accounts.LocalIdentity,
            accounts.LDAPIdentity,
            accounts.OIDCIdentity,
            accounts.ShibIdentity,
        )
        users = {
            identity.user
            for model in identity_types
            for identity in model.query.filter_by(username=value)
        }

    if len(users) != 1:
        sys.exit(f"No unique user '{value}' found (use the user ID).")

    return users.pop()


def oidc_client(args):
    if not oidc_enabled():
        sys.exit("The OIDC provider is disabled; set KADI_OIDC_PROVIDER=true first.")

    for uri in args.redirect_uri:
        parts = urlsplit(uri)
        # Kadi's own form accepts any absolute URI without a fragment.
        if parts.scheme not in ("http", "https") or not parts.netloc or parts.fragment:
            sys.exit(f"Invalid redirect URI '{uri}': must be absolute, no fragment.")

    owner = find_user(args.owner)
    client_uri = args.uri or "{0.scheme}://{0.netloc}".format(
        urlsplit(args.redirect_uri[0])
    )
    client = next(
        (
            client
            for client in OAuth2ServerClient.query.filter_by(user_id=owner.id)
            if client.client_metadata.get("client_name") == args.name
        ),
        None,
    )

    if client is None:
        secret = OAuth2ServerClient.new_client_secret()
        client = OAuth2ServerClient.create(
            user=owner,
            client_name=args.name,
            client_uri=client_uri,
            redirect_uris=args.redirect_uri,
            scope=OIDC_SCOPE,
            client_secret=secret,
        )
        db.session.commit()
        info(f"Registered OIDC client '{args.name}' owned by user {owner.id}.")
        print(f"OIDC_CLIENT_ID={client.client_id}")
        print(f"OIDC_CLIENT_SECRET={secret}")
        return

    wanted = {
        "client_uri": client_uri,
        "redirect_uris": args.redirect_uri,
        "scope": OIDC_SCOPE,
    }
    changed = sorted(k for k, v in wanted.items() if client.client_metadata.get(k) != v)
    if changed:
        client.update_client_metadata(**wanted)
        db.session.commit()
        info(f"Updated {', '.join(changed)} of OIDC client '{args.name}'.")
    else:
        info(f"OIDC client '{args.name}' already exists and is up to date.")

    info("Its secret was shown on creation. To get a new one, delete the client under")
    info("Settings > Applications and rerun this command.")
    print(f"OIDC_CLIENT_ID={client.client_id}")


def token(args):
    available = get_access_token_scopes()
    scopes = sorted(set(args.scope.split()))
    invalid = [
        scope
        for scope in scopes
        if scope.partition(".")[2] not in available.get(scope.partition(".")[0], [])
    ]
    if not scopes or invalid:
        valid = [f"{obj}.{action}" for obj, acts in available.items() for action in acts]
        sys.exit(f"Invalid scopes {invalid or '(none given)'}. Valid: {' '.join(valid)}")

    user = find_user(args.user)
    if user.is_sysadmin:
        sys.exit(
            f"User {user.id} is a sysadmin. Create a dedicated user for the service"
            " (kadi users create) and give it access only to what it needs."
        )

    existing = PersonalToken.query.filter_by(user_id=user.id, name=args.name).first()
    if existing is not None:
        problems = []
        if sorted(existing.scope.split()) != scopes:
            problems.append(f"has the scopes '{existing.scope}'")
        if existing.is_expired:
            problems.append("has expired")
        if problems:
            sys.exit(
                f"Token '{args.name}' of user {user.id} {' and '.join(problems)}. Delete"
                " it under Settings > Access tokens (as that user) and rerun this command."
            )
        info(f"Token '{args.name}' of user {user.id} exists; it was shown on creation.")
        return

    expires_at = None
    if args.expires_days:
        expires_at = utcnow() + timedelta(days=args.expires_days)

    value = PersonalToken.new_token()
    PersonalToken.create(
        user=user,
        name=args.name,
        scope=" ".join(scopes),
        expires_at=expires_at,
        token=value,
    )
    db.session.commit()
    info(f"Created token '{args.name}' for user {user.id}, scopes: {' '.join(scopes)}.")
    print(f"KADI_SERVICE_TOKEN={value}")


def main():
    parser = argparse.ArgumentParser(
        prog="kadi-provision",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)

    client = commands.add_parser("oidc-client", help="register an OIDC client")
    client.add_argument("--owner", required=True, help="user ID or username")
    client.add_argument("--name", required=True, help="client name, shown to users")
    client.add_argument(
        "--redirect-uri", required=True, action="append", help="repeat for several"
    )
    client.add_argument("--uri", help="client website (default: redirect URI origin)")
    client.set_defaults(run=oidc_client)

    pat = commands.add_parser("token", help="create a personal access token")
    pat.add_argument("--user", required=True, help="user ID or username")
    pat.add_argument("--name", required=True, help="token name")
    pat.add_argument("--scope", required=True, help='e.g. "record.read record.update"')
    pat.add_argument("--expires-days", type=int, help="default: never expires")
    pat.set_defaults(run=token)

    args = parser.parse_args()
    with create_app().app_context():
        args.run(args)


if __name__ == "__main__":
    main()
