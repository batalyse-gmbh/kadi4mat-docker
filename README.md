# Kadi4Mat in Docker

There is no official Docker deployment for Kadi4Mat. The official docs only describe running
PostgreSQL/Redis/Elasticsearch as containers *for development*. This stack follows the
[manual production installation](https://kadi.readthedocs.io/en/stable/installation/production/manual.html),
with each systemd service turned into a container, but is meant to sit behind your own
HTTPS reverse proxy (Caddy, Traefik, nginx, ...) instead of Apache.

| Service         | Replaces (official setup)                                          |
| --------------- | ------------------------------------------------------------------ |
| `kadi`          | `kadi-uwsgi` + Apache's static file serving. Runs `kadi db init` and `kadi search init` on every start, which also applies migrations after upgrades |
| `celery`        | `kadi-celery`                                                      |
| `celerybeat`    | `kadi-celerybeat`                                                  |
| `redis`         | Redis 7                                                            |
| `elasticsearch` | Elasticsearch 8.19, single node, heap locked in memory             |
| `postgres`      | PostgreSQL 17, **optional** (profile `postgres`)                   |
| `caddy`         | Apache as TLS proxy, **optional** (profile `caddy`)                |
| `init-permissions` | One-shot, only with `compose.bind-mounts.yml`: creates data directories and fixes their ownership |

Optional features are switched on in `.env` only; `docker-compose.yml` never needs editing:

| Setting in `.env`                                   | Effect                                           |
| --------------------------------------------------- | ------------------------------------------------ |
| `COMPOSE_PROFILES=postgres` / `caddy`               | Bundled PostgreSQL / bundled HTTPS proxy          |
| `COMPOSE_FILE=...:compose.bind-mounts.yml`          | Data in host directories under `KADI_DATA_DIR`    |
| `COMPOSE_FILE=...:compose.external-network.yml`     | Join an existing network (`EXTERNAL_NETWORK`)     |
| `COMPOSE_FILE=...:compose.db-network.yml`           | Also join the database's network (`DB_NETWORK`)   |
| `KADI_OIDC_PROVIDER=true`                           | Kadi acts as an OpenID Connect provider           |

`COMPOSE_FILE` is colon separated and must start with `docker-compose.yml`, e.g.
`COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml:compose.external-network.yml`.

## Setup

```sh
cp .env.example .env   # see the comments in the file
docker compose up -d --build --wait
docker compose exec kadi kadi users create      # prints an initial password
docker compose exec kadi kadi users sysadmin 1
```

Kadi refuses to start while `.env` still contains placeholders: `KADI_SECRET_KEY` must not
be `change-me` and needs at least 32 characters, `POSTGRES_PASSWORD` must not be
`change-me`, and `KADI_SERVER_NAME` must not be an `example.*` domain. `docker compose logs
kadi` then lists every problem. While `KADI_SMTP_HOST` is `localhost`, it logs a warning,
because mail would silently go nowhere.

All long-running services have healthchecks, so `docker compose up --wait` only succeeds
once everything actually runs:

- `kadi`: port 8000 accepts connections.
- `celery`: the worker answers `celery inspect ping`.
- `celerybeat`: the scheduler finished starting (its schedule file, deleted on every start,
  exists again). There is no cheaper liveness signal: Kadi's only periodic task runs
  hourly. If beat crashes later, the container stops and restarts.

## Data location

By default all data lives in named Docker volumes. To keep it in host directories instead
(e.g. `/data/kadi`), set in `.env`:

```sh
COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml
KADI_DATA_DIR=/data/kadi
```

The one-shot `init-permissions` service creates the subdirectories and sets their owners
before the other services start. That matters because Docker creates missing bind-mount
directories as `root:root`, which crashes the non-root services (Elasticsearch with
`AccessDeniedException: .../node.lock`). It runs on every `up`, and only changes ownership
recursively when a file has the wrong owner, so data restored as root is fixed too.

| Directory                       | Owner (uid:gid) | Image user                     |
| ------------------------------- | --------------- | ------------------------------ |
| `postgres/`                     | `999:999`       | `postgres` in `postgres:17`    |
| `redis/`                        | `999:999`       | `redis` in `redis:7`           |
| `elasticsearch/`                | `1000:0`        | `elasticsearch` in the ES 8.x image |
| `storage/`, `uploads/`          | `10001:10001`   | `kadi` in this image           |
| `oidc/` (mode 700)              | `10001:10001`   | `kadi` in this image           |
| `caddy/data/`, `caddy/config/`  | `0:0`           | `caddy:2` runs as root         |

Directories for disabled services (e.g. `postgres/` with an external database) are created
anyway and stay empty. Switching an existing installation over does not copy data from the
named volumes; copy it first, e.g.
`docker run --rm -v kadi4mat_storage:/from -v /data/kadi/storage:/to alpine cp -a /from/. /to/`
for each volume, with the stack stopped.

## Reverse proxy

Kadi serves plain HTTP on port 8000. Your proxy must terminate TLS: Kadi's production
config uses secure cookies, so login does not work over plain HTTP. `KADI_SERVER_NAME` must
be the public hostname exactly (with port, if not 443), or every route returns 404.

**Caddy on the host** (`KADI_HTTP_BIND=127.0.0.1:8000`, the default):

```caddyfile
kadi4mat.example.edu {
	reverse_proxy 127.0.0.1:8000
}
```

**Caddy as a container**: add `compose.external-network.yml` to `COMPOSE_FILE` and set
`EXTERNAL_NETWORK=<caddy's network>`, then use `reverse_proxy kadi4mat-kadi:8000`. This
attaches `kadi`, `celery` and `celerybeat` to that network (the `kadi4mat-kadi` alias is on
`kadi` only). The `127.0.0.1:8000` port binding is harmless in that case.
(`compose.proxy-network.yml` and `PROXY_NETWORK` from earlier versions are replaced by this.)

Attach external networks only through these override files. Adding one to the `x-kadi`
anchor in `docker-compose.yml` as well declares it twice per container. Depending on the
Compose version, that silently drops one entry (including the `kadi4mat-kadi` alias) or
fails when containers are recreated.

**No proxy on the host**: add `caddy` to `COMPOSE_PROFILES`. It uses ports 80/443 and gets a
Let's Encrypt certificate for `KADI_SERVER_NAME` automatically.

Kadi trusts the last `X-Forwarded-For` entry (one proxy hop), so **never expose port 8000
publicly**. Direct clients could spoof their IP to bypass rate limiting. If there is a
second proxy in front of yours (e.g. Cloudflare), configure `trusted_proxies` in Caddy.

## Existing PostgreSQL server

Remove `postgres` from `COMPOSE_PROFILES` and set `POSTGRES_HOST`/`POSTGRES_PORT`.
PostgreSQL >= 13 is required.

- **Server directly on the Docker host**: `POSTGRES_HOST=host.docker.internal`. It must
  listen on the Docker bridge interface (`listen_addresses`) and allow the bridge subnet in
  `pg_hba.conf`.
- **PostgreSQL container on a Docker network**: `POSTGRES_HOST=<container name>`, and
  `kadi`, `celery` and `celerybeat` must join that network:
  - Same network as your proxy container: `compose.external-network.yml` with
    `EXTERNAL_NETWORK` covers both.
  - Different network: additionally add `compose.db-network.yml` with `DB_NETWORK`. It must
    differ from `EXTERNAL_NETWORK`; use `compose.external-network.yml` alone if they match.

  Container names on shared networks resolve for everyone on them. Avoid names like
  `redis` or `elasticsearch` for other containers there, or Kadi may reach the wrong one.

Create the role and database once; Kadi creates the tables itself on first start:

```sql
CREATE ROLE kadi LOGIN PASSWORD '...';
CREATE DATABASE kadi OWNER kadi ENCODING 'UTF8' TEMPLATE template0;
```

If the server is unreachable, `kadi` retries for about 2.5 minutes before exiting.

## OIDC provider

Since version 1.8, Kadi can act as an OpenID Connect provider, so other applications can
log users in with their Kadi account. Enable it with `KADI_OIDC_PROVIDER=true`.

On startup, `kadi` generates a 3072 bit RSA signing key at `/opt/kadi/oidc/signing-key.pem`
if it is missing (`oidc` volume, or `KADI_DATA_DIR/oidc/` with bind mounts, readable only
by uid 10001). It then checks every configured key and refuses to start if one is missing,
unreadable or not RSA. Kadi itself would only fail while issuing a token, with an HTTP 500
after the authorization code was already used. Include the key in backups.

Endpoints, with the issuer `https://<KADI_SERVER_NAME>`:

| Purpose        | URL                                   |
| -------------- | ------------------------------------- |
| Discovery      | `/.well-known/openid-configuration`   |
| Authorization  | `/oauth/authorize`                    |
| Token          | `/oauth/token`                        |
| JWKS           | `/oauth/jwks.json`                    |
| User info      | `/api/oauth/userinfo`                 |
| Revocation     | `/oauth/revoke`                       |

Kadi serves these even while the provider is disabled, but without keys the JWKS is empty
and ID tokens cannot be signed. All URLs must come out as `https://` on your public
hostname: that requires `KADI_SERVER_NAME` to be exact and the proxy to send
`X-Forwarded-Proto` (Caddy does by default).

**Registering a client application** works only in the web UI: log in as the user who
should own the client, open *Settings → Applications* (`/settings/applications`), enter
the redirect URIs (exact match, one per line) and tick the *OpenID Connect* scopes
(`openid`, `profile`, `email`; stored as `oidc.openid` etc.). They only appear while the
provider is enabled. Kadi shows the client secret once, after registering.

Things client developers need to know:

- Only the authorization code flow is supported. The client must authenticate at the token
  endpoint with `client_secret_post` (credentials in the form body); HTTP Basic is rejected.
  PKCE (`S256`) and `nonce` are optional but honoured.
- The granted scopes are always the ones registered for the client, whatever the request
  asks for.
- `sub` is Kadi's numeric user ID as a string. It is stable, unlike the email address, so
  identify users by (issuer, `sub`).
- Claims: `profile` gives `name` and `preferred_username`, `email` gives `email` and
  `email_verified`. Careful: Kadi puts the **username** into `name` and the **display name**
  into `preferred_username`, the reverse of the usual meaning.
- ID tokens and access tokens are valid for one hour. Refresh tokens do not expire, are
  rotated on every use, and a refresh returns no new ID token.
- Each user holds one token per client: a new login (e.g. on a second device) revokes the
  previous tokens of that user for that client.

**Rotating the key**: generate a new one and list it first, keeping the old one for
verification of tokens issued before the switch:

```sh
docker compose exec kadi kadi-oidc-keys generate /opt/kadi/oidc/signing-key-2.pem
# .env: KADI_OIDC_SIGNING_KEYS=/opt/kadi/oidc/signing-key-2.pem,/opt/kadi/oidc/signing-key.pem
docker compose up -d
```

Remove the old key from the list after the ID token lifetime (one hour) plus however long
your clients cache the JWKS. Never overwrite a key file in place.

## Differences from the official Apache setup

- **File downloads are streamed by uWSGI**, not handed to the web server via `X-Sendfile`
  (a generic proxy cannot do that). Downloads run on offload threads, so they do not block
  workers. The trade-off: **no HTTP range requests**, since Kadi only enables them when the
  web server handles files. Interrupted downloads restart from the beginning, and
  multi-connection download managers fall back to a single stream.
- Static files and favicons are served by uWSGI (with one-year cache headers on `/static`).

## Notes

- **Email does not work by default.** `localhost` inside a container is the container itself,
  so set `KADI_SMTP_*` to a real mail server, or password resets and notifications are lost.
- Elasticsearch needs `vm.max_map_count >= 262144` on the Docker host. Its heap is locked
  in memory (`bootstrap.memory_lock`); if the host does not allow that (e.g. rootless
  Docker), Elasticsearch logs a warning and runs unlocked. `ELASTICSEARCH_VERSION` selects
  the image tag; stay on 8.x, Kadi 1.12 does not support Elasticsearch 9.
- Other [configuration options](https://kadi.readthedocs.io/en/stable/installation/configuration.html)
  go into `config/kadi.py`, then run `docker compose up -d --build`.
- Upgrade: change `KADI_VERSION` in `.env`, then run `docker compose up -d --build`.
- Backups: the database, plus the `storage` and `uploads` volumes (and `oidc` with the OIDC
  provider enabled). Search indices can be
  rebuilt with `kadi search reindex`.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

- `scripts/check-compose.sh`: `docker compose config` for every profile/override
  combination, plus checks for services referencing the same network twice and for named
  volumes left over with `compose.bind-mounts.yml`. Run it locally before changing compose
  files (needs `jq`).
- hadolint on the `Dockerfile` (see `.hadolint.yaml` for the ignored rule).
- Image build, then a smoke test with the bundled PostgreSQL, once with named volumes and
  once with `compose.bind-mounts.yml`: all services must become healthy and the login page
  must load. It also checks that placeholder configuration is rejected.
