# Kadi4Mat configuration. This is a Python file, values are read from the container
# environment (see .env.example). Any other option from
# https://kadi.readthedocs.io/en/stable/installation/configuration.html can be added here.
import os
from urllib.parse import quote_plus


# Placeholders from .env.example that must never reach a running instance.
_PLACEHOLDER = "change-me"
_EXAMPLE_DOMAINS = ("example.com", "example.org", "example.net", "example.edu", "example")
_errors = []


def _env(name, default=None, required=False):
    value = os.environ.get(name, default)

    if required and not value:
        _errors.append(f"{name} must be set.")

    return value


def _env_bool(name, default=False):
    return _env(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


AUTH_PROVIDERS = [
    {
        "type": "local",
        "allow_registration": _env_bool("KADI_ALLOW_REGISTRATION", False),
        "email_confirmation_required": _env_bool(
            "KADI_EMAIL_CONFIRMATION_REQUIRED", False
        ),
    }
]

SERVER_NAME = _env("KADI_SERVER_NAME", required=True) or ""
SECRET_KEY = _env("KADI_SECRET_KEY", required=True) or ""

_host = SERVER_NAME.rsplit(":", 1)[0].lower().rstrip(".")
if any(_host == domain or _host.endswith(f".{domain}") for domain in _EXAMPLE_DOMAINS):
    _errors.append(
        f"KADI_SERVER_NAME is the placeholder domain '{SERVER_NAME}'. Set it to the"
        " public hostname of this instance."
    )

if SECRET_KEY == _PLACEHOLDER or (SECRET_KEY and len(SECRET_KEY) < 32):
    _errors.append(
        "KADI_SECRET_KEY must be a random value of at least 32 characters. Generate one"
        ' with: python3 -c "import secrets; print(secrets.token_hex(32))"'
    )

if os.environ.get("POSTGRES_PASSWORD") == _PLACEHOLDER:
    _errors.append("POSTGRES_PASSWORD is still the placeholder 'change-me'.")

SQLALCHEMY_DATABASE_URI = "postgresql://{user}:{password}@{host}:{port}/{db}?sslmode={sslmode}".format(
    user=quote_plus(_env("POSTGRES_USER", "kadi")),
    password=quote_plus(_env("POSTGRES_PASSWORD", required=True) or ""),
    host=_env("POSTGRES_HOST", "postgres"),
    port=_env("POSTGRES_PORT", "5432"),
    db=_env("POSTGRES_DB", "kadi"),
    sslmode=_env("POSTGRES_SSLMODE", "prefer"),
)

# Kadi always sits behind exactly one HTTP reverse proxy (yours or the bundled Caddy), so
# take the client IP from the last X-Forwarded-For entry that proxy appended. Rate limiting
# and session protection rely on it. Consequently, port 8000 must not be publicly reachable.
PROXY_FIX_HEADERS = {"x_for": 1, "x_proto": 1}

# The official Apache setup lets the web server resolve "X-Sendfile". A generic reverse
# proxy cannot, so uWSGI streams files itself (see uwsgi.ini). This keeps Kadi's response
# headers (Content-Disposition, Content-Type, CSP, nosniff) intact.
USE_X_SENDFILE = False

# OIDC provider (opt-in): Kadi signs ID tokens with the first key and publishes all of them
# in /oauth/jwks.json, so older keys can stay listed during a rotation. Keys are RSA PEM
# files; the entrypoint generates the default one on first start and checks all of them.
if _env_bool("KADI_OIDC_PROVIDER", False):
    OIDC_SIGNING_KEYS = [
        path.strip()
        for path in _env("KADI_OIDC_SIGNING_KEYS", "").split(",")
        if path.strip()
    ] or ["/opt/kadi/oidc/signing-key.pem"]

    if any(not os.path.isabs(path) for path in OIDC_SIGNING_KEYS):
        _errors.append("KADI_OIDC_SIGNING_KEYS must only contain absolute paths.")

STORAGE_PATH = "/opt/kadi/storage"
MISC_UPLOADS_PATH = "/opt/kadi/uploads"

CELERY_BROKER_URL = _env("KADI_REDIS_URL", "redis://redis:6379/0")

# Worker processes. Kadi's default, min(CPU count, 10), suits a host running one instance;
# each process holds its own copy of the app.
if _env("KADI_CELERY_CONCURRENCY"):
    try:
        CELERY_WORKER_CONCURRENCY = int(_env("KADI_CELERY_CONCURRENCY"))
    except ValueError:
        CELERY_WORKER_CONCURRENCY = 0
    if CELERY_WORKER_CONCURRENCY < 1:
        _errors.append("KADI_CELERY_CONCURRENCY must be a positive number.")
RATELIMIT_STORAGE_URI = _env("KADI_REDIS_URL", "redis://redis:6379/0")
ELASTICSEARCH_HOSTS = [_env("KADI_ELASTICSEARCH_HOST", "http://elasticsearch:9200")]

SMTP_HOST = _env("KADI_SMTP_HOST", "localhost")
SMTP_PORT = int(_env("KADI_SMTP_PORT", "25"))
SMTP_USERNAME = _env("KADI_SMTP_USERNAME", "")
SMTP_PASSWORD = _env("KADI_SMTP_PASSWORD", "")
SMTP_USE_TLS = _env_bool("KADI_SMTP_USE_TLS", True)
MAIL_NO_REPLY = _env("KADI_MAIL_NO_REPLY", f"no-reply@{SERVER_NAME}")

if _errors:
    # SystemExit instead of an exception: every process loading this file (uWSGI, Celery,
    # CLI) stops with just this message instead of a traceback.
    raise SystemExit(
        "Invalid Kadi configuration (check .env):\n"
        + "\n".join(f"  - {error}" for error in _errors)
    )
