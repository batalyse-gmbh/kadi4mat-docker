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
| `redis`         | Redis 8                                                            |
| `elasticsearch` | Elasticsearch 8.19, single node, heap locked in memory             |
| `postgres`      | PostgreSQL 18, **optional** (profile `postgres`)                   |
| `caddy`         | Apache as TLS proxy, **optional** (profile `caddy`)                |
| `init-permissions` | One-shot, only with `compose.bind-mounts.yml`: creates data directories and fixes their ownership |

To run several instances on one host, see [Several instances on one host](#several-instances-on-one-host).

Optional features are switched on in `.env` only; `docker-compose.yml` never needs editing:

| Setting in `.env`                                   | Effect                                           |
| --------------------------------------------------- | ------------------------------------------------ |
| `COMPOSE_PROFILES=postgres` / `caddy`               | Bundled PostgreSQL / bundled HTTPS proxy          |
| `COMPOSE_FILE=...:compose.bind-mounts.yml`          | Data in host directories under `KADI_DATA_DIR`    |
| `COMPOSE_FILE=...:compose.external-network.yml`     | Join an existing network (`EXTERNAL_NETWORK`)     |
| `COMPOSE_FILE=...:compose.db-network.yml`           | Also join the database's network (`DB_NETWORK`)   |
| `COMPOSE_FILE=...:compose.embedded-beat.yml`        | Scheduler inside the `celery` worker, no `celerybeat` container |
| `KADI_OIDC_PROVIDER=true`                           | Kadi acts as an OpenID Connect provider           |
| `KADI_PLUGINS=...`                                  | Kadi plugins, e.g. the [Batalyse Collect embed](#batalyse-collect-embed) |

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
| `postgres/`                     | `999:999`       | `postgres` in `postgres:18`    |
| `redis/`                        | `999:999`       | `redis` in `redis:8`           |
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
be the public hostname exactly (with port, if not 443): Kadi builds every absolute URL (links,
redirects, emails, OIDC issuer and endpoints) from it, whatever `Host` the request has.

**Caddy on the host** (`KADI_HTTP_BIND=127.0.0.1:8000`, the default):

```caddyfile
kadi4mat.example.edu {
	reverse_proxy 127.0.0.1:8000
}
```

**Caddy as a container**: add `compose.external-network.yml` to `COMPOSE_FILE` and set
`EXTERNAL_NETWORK=<caddy's network>`, then use `reverse_proxy kadi4mat-kadi:8000`. This
attaches `kadi`, `celery` and `celerybeat` to that network (the `kadi4mat-kadi` alias is on
`kadi` only). The alias is `<compose project name>-kadi`, so instances started with
`scripts/instance.sh` each get their own. The `127.0.0.1:8000` port binding is harmless in that case.
(`compose.proxy-network.yml` and `PROXY_NETWORK` from earlier versions are replaced by this.)

Attach external networks only through these override files. Adding one to the `x-kadi`
anchor in `docker-compose.yml` as well declares it twice per container. Compose 5.5
collapses that into one attachment, but the outcome is version dependent (this is what the
original deployment ran into), so `scripts/check-compose.sh` treats it as an error.

**No proxy on the host**: add `caddy` to `COMPOSE_PROFILES`. It uses ports 80/443 and gets a
Let's Encrypt certificate for `KADI_SERVER_NAME` automatically.

Kadi trusts the last `X-Forwarded-For` entry (one proxy hop), so **never expose port 8000
publicly**. Direct clients could spoof their IP to bypass rate limiting. If there is a
second proxy in front of yours (e.g. Cloudflare), configure `trusted_proxies` in Caddy.

## Several instances on one host

Several instances run from one checkout and one image, each as its own compose project.
Your PostgreSQL server and reverse proxy serve all of them: one role and database per
instance, one site block per instance.

Elasticsearch, `celery` and `redis` stay per instance:

- Kadi 1.12 names its search indices after its tables (`record`, `collection`, `group`,
  `template`) and has no setting for a prefix, so instances sharing an Elasticsearch
  would mix up each other's search results.
- A Celery worker loads one instance's configuration (database, storage, server name) and
  runs every task against it; it cannot serve a second instance. Redis only carries that
  worker's queue and takes a few MB.

What can be reduced is the per-instance footprint. Measured with Kadi 1.12 on a 16 CPU host
after startup:

| Per instance                              | Default                          | Reduced |
| ----------------------------------------- | -------------------------------- | ------- |
| `celery` + `celerybeat`                   | ~1.1 GB (10 worker processes + separate scheduler) | ~270 MB with `KADI_CELERY_CONCURRENCY=2` and `compose.embedded-beat.yml` |
| `elasticsearch`                           | ~1.8 GB with the default 1 GB heap | lower `ES_JAVA_OPTS`, e.g. `-Xms512m -Xmx512m` for small instances |
| `kadi`                                    | ~150 MB with `UWSGI_PROCESSES=4` | fewer processes for low traffic |

`KADI_CELERY_CONCURRENCY` defaults to one worker process per CPU (at most 10); Kadi's
background tasks (uploads, exports, cleanup) are infrequent, so 1-2 suffice for most
instances. `compose.embedded-beat.yml` runs the scheduler inside the worker, which is safe
as long as each instance has exactly one `celery` container.

**Setup**: configure each instance in `instances/<name>.env`, copied from `.env.example`,
and run every compose command for it through `scripts/instance.sh`:

```sh
cp .env.example instances/a.env    # then edit it
scripts/instance.sh a up -d --build --wait
scripts/instance.sh a exec kadi kadi users create
scripts/instance.sh a logs -f celery
```

The script runs the instance as compose project `kadi4mat-a` and gives Compose and the
containers the same file, so containers, volumes and networks stay apart and an instance
can never start with another's settings. Plain `docker compose` with `.env` keeps working,
as project `kadi4mat`. Per instance, these must differ:

- `KADI_SERVER_NAME`, `KADI_SECRET_KEY`
- `POSTGRES_DB` and `POSTGRES_USER` (see [Existing PostgreSQL server](#existing-postgresql-server))
- `KADI_HTTP_BIND` (a free port each) for a proxy on the host; a proxy container on
  `EXTERNAL_NETWORK` uses `kadi4mat-<name>-kadi:8000` instead
- `KADI_DATA_DIR` with `compose.bind-mounts.yml`

For example, `instances/a.env` next to your existing proxy and database containers:

```sh
COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml:compose.external-network.yml:compose.embedded-beat.yml
COMPOSE_PROFILES=
KADI_SERVER_NAME=kadi-a.example.org
KADI_DATA_DIR=/data/kadi/a
EXTERNAL_NETWORK=proxy
POSTGRES_HOST=my-postgres
POSTGRES_DB=kadi_a
POSTGRES_USER=kadi_a
KADI_CELERY_CONCURRENCY=2
ES_JAVA_OPTS=-Xms512m -Xmx512m
```

All instances use the one image built from this checkout, including `config/kadi.py`.
After changing `KADI_VERSION` or the config, rebuild once and recreate every instance
(`scripts/instance.sh <name> up -d --build`).

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

**Registering a client application**: register the client in the web UI. Log in as the
user who should own the client, open *Settings → Applications* (`/settings/applications`), enter
the redirect URIs (exact match, one per line) and tick the *OpenID Connect* scopes
(`openid`, `profile`, `email`; stored as `oidc.openid` etc.). They only appear while the
provider is enabled. Kadi shows the client secret once, after registering. For Batalyse
Collect, the redirect URI is `<Collect URL>/API/auth/oidc/callback`.

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

## Access tokens for services

Services that call Kadi's API, such as Collect's service account, authenticate with a
personal access token. Give each service its own regular user, not a sysadmin (a token acts
with all rights of its user), and a token with only the scopes the service needs. Create
the user on the command line, which prints its initial password:

```sh
docker compose exec kadi kadi users create -d "Collect service" -u collect-service \
  -e collect-service@example.org
```

Then log in as that user, open *Settings → Access tokens* and create a token with those
scopes only (for Collect: `record.read` and `record.update`). The form pre-fills *Expires
at* with four weeks from now: clear the field for a token that never expires, or pick a
date and plan the renewal. Once the token expires, every Kadi call of the service fails
with HTTP 401; for Collect, the embed and the file transfer with Kadi stop working. Kadi
shows the token once, after creating it. Like any user, the service user only reaches
records it has a role on.

## Plugins

Kadi's built-in plugins (`influxdb`, `s3`, `tib_ts`, `zenodo`) are part of the image. Any
other plugin is installed from a wheel: put the `.whl` file into `plugins/` and rebuild
(`docker compose up -d --build`). The build installs the wheels together with the pinned
`kadi` version. That installs a plugin's dependencies, but fails the build rather than
replace Kadi or change a version Kadi pins. Git ignores `plugins/*.whl`.

Enable plugins with `KADI_PLUGINS` (comma separated). Kadi silently skips a name it cannot
find, so the config refuses to start if a plugin is not installed and lists the installed
ones. Plugin settings not covered below go at the end of `config/kadi.py`, one entry per
plugin: `PLUGIN_CONFIG["<plugin>"] = {...}`. The file already fills `PLUGIN_CONFIG` (e.g.
for the Collect embed), so never assign `PLUGIN_CONFIG = {...}` itself.

## Batalyse Collect embed

The `kadi-collect-embed` plugin shows Batalyse Collect's form on every record page, in a
frame, and signs the Kadi user in to Collect. No token appears in the page: the Kadi server
requests a short-lived Collect session (`POST /API/kadi/embed-session`) with a shared
secret. The plugin is not on PyPI: Batalyse supplies it as a wheel
(`kadi_collect_embed-<version>-py3-none-any.whl`). Put it into `plugins/`, set it up in
`.env` and rebuild (`docker compose up -d --build`):

```sh
KADI_PLUGINS=collect_embed
COLLECT_EMBED_BROWSER_BASE_URL=https://collect.example.org
COLLECT_EMBED_SERVER_BASE_URL=
COLLECT_EMBED_SERVICE_SECRET=<python3 -c "import secrets; print(secrets.token_hex(32))">
```

- `COLLECT_EMBED_BROWSER_BASE_URL`: Collect's origin as users' browsers load it. It is the
  frame's source and the origin added to Kadi's CSP `frame-src`. It must be https: Kadi is
  served over https, and browsers block an http frame inside it.
- `COLLECT_EMBED_SERVER_BASE_URL`: Collect's origin as the `kadi` container reaches it, for
  the session request. Empty means the browser URL.
- `COLLECT_EMBED_SERVICE_SECRET`: must equal Collect's `KADI_EMBED_SERVICE_SECRET`. Only the
  Kadi server sends it, to Collect; it never reaches a browser.

With the plugin enabled, Kadi refuses to start while a URL is missing, not an origin
(scheme, host and optional port; no path, query, fragment, credentials or spaces) or on a
placeholder domain (`example`, or `example.com`, `.org`, `.net`, `.edu` and their
subdomains), the browser URL is not https, or the secret is shorter than
32 characters. Otherwise a missing setting only shows up as an HTTP 500 once a user opens a
record. Only the web process (`kadi`) serves the plugin's routes.

To build the wheel from a checkout of the Batalyse monorepo, without writing into it:

```sh
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v <monorepo>/integrations/kadi-collect-embed:/src:ro -v "$PWD/plugins:/out" \
  python:3.13-slim-trixie sh -c 'cp -r /src /tmp/src && pip wheel --no-deps -w /out /tmp/src'
```

Collect needs, in its own configuration:

- `OIDC_ISSUER_URL=https://<KADI_SERVER_NAME>`: Collect must use this Kadi as its OIDC
  login provider, with the same origin as the Kadi URL browsers use (`KADI_BROWSER_HOST`),
  or it refuses the embed session. Register Collect as a client application with the
  redirect URI `<Collect URL>/API/auth/oidc/callback` (see [OIDC provider](#oidc-provider)).
- `KADI_EMBED_SERVICE_SECRET`: the same value as `COLLECT_EMBED_SERVICE_SECRET`.
- `KADI_SERVICE_TOKEN`: a token with `record.read record.update` of a dedicated user (see
  [Access tokens for services](#access-tokens-for-services)). Collect reads and writes the
  records users open in the embed with it, so that user needs access to them: share the
  records with it (directly or through a group), or give it the system role `admin`,
  which grants access to every record (sysadmins can change a user's system role in the
  web UI). The token's scopes still limit it to reading and updating records.

How Kadi users map to Collect accounts is described in the plugin's README.

### Collect on the same host

With Collect's containers on the same host, behind the same reverse proxy, Collect's
settings for `https://kadi.example.org` are:

| Collect setting     | Value                                                            |
| ------------------- | ---------------------------------------------------------------- |
| `KADI_HOST`         | `https://kadi.example.org`, or the internal alias (see below)    |
| `KADI_BROWSER_HOST` | `https://kadi.example.org`                                       |
| `OIDC_ISSUER_URL`   | `https://kadi.example.org`                                       |

Public URLs work as long as the containers can resolve and reach the public hostnames: the
requests leave through the proxy and come back in. The OIDC issuer must be the public URL in
any case, because Kadi builds the issuer and all OIDC endpoints from `KADI_SERVER_NAME`.

Internal addresses avoid that detour when Collect's container shares a Docker network with
`kadi` (`compose.external-network.yml`, e.g. the proxy's network):

- `KADI_HOST=http://kadi4mat-kadi:8000` (the [alias](#reverse-proxy)), plus
  `KADI_TRUSTED_HOSTS=kadi4mat-kadi` for Collect, whose SSRF guard refuses private
  plain-http addresses otherwise. Tested on the Kadi side only: through the alias, a token
  could read a record, upload a file and download it. Kadi answers whatever the `Host`
  header, but the absolute URLs in its responses (`_links`, `_actions`) read
  `http://<KADI_SERVER_NAME>/...`, because no proxy sets `X-Forwarded-Proto`. Collect only
  follows action URLs on its `KADI_HOST` origin and builds the paths itself otherwise, so
  this should not matter. Collect has not been run against this setup, though. The token
  travels unencrypted on that Docker network.
- `COLLECT_EMBED_SERVER_BASE_URL=http://<Collect container>:<port>` on the same network, for
  the session request. Untested.

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
  Docker), Elasticsearch should log a warning and run unlocked, since a single-node setup
  does not enforce bootstrap checks (not tested). `ELASTICSEARCH_VERSION` selects
  the image tag; stay on 8.x, Kadi 1.12 does not support Elasticsearch 9.
- Other [configuration options](https://kadi.readthedocs.io/en/stable/installation/configuration.html)
  go at the end of `config/kadi.py`, then run `docker compose up -d --build`.
- Upgrade: change `KADI_VERSION` in `.env`, then run `docker compose up -d --build`.
- The bundled PostgreSQL is pinned to major version 18. A newer major version cannot read
  its data directory: moving on needs `pg_upgrade` or a dump and restore, never just a new
  image tag. PostgreSQL 18 keeps its data in `18/docker` below the volume (mounted at
  `/var/lib/postgresql`), so an upgraded cluster can sit next to it.
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
  So are an uninstalled plugin in `KADI_PLUGINS` and invalid `COLLECT_EMBED_*` settings
  (the plugin itself is not in CI).
  PostgreSQL must keep its data in `18/docker` on its one mount.
- A third smoke test (`scripts/smoke-test.sh instances`) starts two instances through
  `scripts/instance.sh` on one network, with `compose.embedded-beat.yml` and
  `KADI_CELERY_CONCURRENCY=1`: each alias must reach its own instance, and each worker must
  run the scheduler with one process.
