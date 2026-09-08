#!/usr/bin/env bash
# deploy/install.sh — the onboarding door (ADR-016 §4): no text editor, no
# hand-copied digests, and — with --up — no second command.
#
#   ./deploy/install.sh --up                     # trial: dev, localhost, generated secrets,
#                                                # stack up, browser → /setup wizard
#   ./deploy/install.sh --env prod --domain books.example.com --acme-email ops@example.com --up
#   ./deploy/install.sh --env prod --domain books.example.com --pin vX.Y.Z         # stable release
#   ./deploy/install.sh --env prod --domain books.example.com --pin vX.Y.Z-beta.N  # a beta
#   ./deploy/install.sh --env prod --domain books.example.com --channel beta       # rolling tag, pinned
#   ./deploy/install.sh --bundle /tmp/hera-vm     # write a transferable deploy bundle
#
#   # No clone at all (prebuilt images only, prod mode):
#   curl -fsSL https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/deploy/install.sh \
#     | bash -s -- --env prod --domain books.example.com --acme-email ops@example.com --up
#
# What it does: creates deploy/.env from .env.example with every secret
# machine-generated (openssl rand), the image registry set to GHCR
# (decision 2026-08-30: GHCR over Docker Hub), and prod allowlists derived
# from --domain. Image digests come from a release's images.env (--pin) or
# from the pulled rolling channel tag (--channel; RepoDigests). Run outside a
# checkout, it fetches the deploy bundle (prod compose, Caddyfile, Postgres
# init) for the pinned version into ./hera-os first. With --up it then runs
# `docker compose up -d --wait` — the one-shot `migrate` service brings the
# schema to head before the api starts — and prints the /setup wizard URL,
# where the first Administrator, company, currency and timezone are created.
#
# Idempotency rule (do not break it): re-running against an existing .env
# refuses to rewrite it without --force (with --up it keeps the file and just
# brings the stack up). Secrets are generated ONCE. HERA_SECRET_KEY rotation
# is a deliberate procedure (HERA_SECRET_KEY_PREVIOUS), and the three DB role
# passwords are written into Postgres only on the first boot of the
# hera-db-data volume (postgres/init-roles.sh) — regenerating them against an
# existing volume locks the site out.
#
# Payment provider keys (Paystack/Flutterwave) and WhatsApp/SMTP credentials
# are deliberately NOT generated: they are per-company settings entered in the
# /setup wizard or the desk (encrypted at rest). The env path is a seed
# convenience only.
set -euo pipefail

# The PUBLIC release repo. Everything a no-clone deploy touches lives here and
# must stay publicly readable, or every one of these 404s for a deployer:
#   ${RAW}/deploy/docker-compose.prod.yml   the standalone bundle (below)
#   ${RAW}/.env.example                     the env template
#   github.com/${REPO}/releases/download/<tag>/images.env   the --pin manifest
# The images themselves are ghcr.io/martinkyng/hera-os-{api,web}; GHCR packages
# default to PRIVATE, so patches/ghcr-public-visibility.patch flips them public
# after each release. Override for a fork or mirror with HERA_REPO=you/repo.
REPO="${HERA_REPO:-MartinKyng/Hera-Operating-System}"
API_IMAGE="ghcr.io/martinkyng/hera-os-api"
WEB_IMAGE="ghcr.io/martinkyng/hera-os-web"
POSTGRES_TAG="postgres:16-alpine"
REDIS_TAG="redis:7-alpine"
CADDY_TAG="caddy:2-alpine"

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

die() { echo "install.sh: error: $*" >&2; exit 1; }
note() { echo "install.sh: $*" >&2; }

need_bin() { command -v "$1" >/dev/null 2>&1 || die "$2"; }

hex() { openssl rand -hex "$1"; }

ENV_MODE="dev"
DOMAIN=""
ADMIN_EMAIL="admin@local.test"
HTTP_PORT=""
ACME_EMAIL=""
PIN=""
CHANNEL=""
BUNDLE_DIR=""
FORCE=0
UP=0
INSTALL_DIR="${HERA_INSTALL_DIR:-./hera-os}"

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_MODE="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="${2:?}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:?}"; shift 2 ;;
    --acme-email) ACME_EMAIL="${2:?}"; shift 2 ;;
    --pin) PIN="${2:?}"; shift 2 ;;
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    --bundle) BUNDLE_DIR="${2:?}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:?}"; shift 2 ;;
    --up) UP=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ "${ENV_MODE}" = "dev" ] || [ "${ENV_MODE}" = "prod" ] || die "--env must be dev or prod"
[ "${ENV_MODE}" = "prod" ] && [ -z "${DOMAIN}" ] && die "--env prod requires --domain (Caddy HTTPS, CORS, trusted hosts derive from it)"
if [ -n "${PIN}" ] && [ -n "${CHANNEL}" ]; then
  die "--pin and --channel are exclusive: a release manifest OR a rolling tag"
fi
if [ -n "${CHANNEL}" ] && [ "${CHANNEL}" != "stable" ] && [ "${CHANNEL}" != "beta" ]; then
  die "--channel must be stable or beta"
fi
need_bin openssl "openssl is required to generate secrets"
need_bin sed "sed is required to write the env file"

# --- where am I: a checkout (or bundle), or a curl'd standalone script? ------
# In a checkout the compose files sit next to this script and the template at
# the repo root; the release bundle keeps env.example next to the script. A
# script piped from curl has neither — it fetches the deploy bundle for the
# requested version into ${INSTALL_DIR} (prod compose only: the dev stack
# builds from source and needs the clone).
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
STANDALONE=0
if [ -n "${SCRIPT_SRC}" ] && [ -f "${SCRIPT_SRC}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SRC}")" && pwd)"
  [ -f "${SCRIPT_DIR}/docker-compose.prod.yml" ] || STANDALONE=1
else
  STANDALONE=1
fi

if [ "${STANDALONE}" = "1" ]; then
  [ "${ENV_MODE}" = "prod" ] || die "outside a checkout only --env prod deploys (prebuilt images); for a localhost trial: git clone https://github.com/${REPO}.git && ./deploy/install.sh --up"
  need_bin curl "curl is required to fetch the deploy bundle"
  case "${PIN:-}" in
    "") BUNDLE_REF="$([ "${CHANNEL:-stable}" = "beta" ] && echo dev || echo main)" ;;
    *)  BUNDLE_REF="${PIN}" ;;
  esac
  mkdir -p "${INSTALL_DIR}/postgres"
  SCRIPT_DIR="$(cd "${INSTALL_DIR}" && pwd)"
  RAW="https://raw.githubusercontent.com/${REPO}/${BUNDLE_REF}"
  note "no checkout here — fetching the deploy bundle (${BUNDLE_REF}) into ${SCRIPT_DIR}"
  for file in deploy/docker-compose.prod.yml:docker-compose.prod.yml \
              deploy/Caddyfile.prod:Caddyfile.prod \
              deploy/postgres/init-roles.sh:postgres/init-roles.sh \
              .env.example:env.example \
              VERSION:VERSION; do
    src="${file%%:*}"; dst="${file#*:}"
    curl -fsSL "${RAW}/${src}" -o "${SCRIPT_DIR}/${dst}" || die "could not fetch ${RAW}/${src}"
  done
  chmod +x "${SCRIPT_DIR}/postgres/init-roles.sh"
  REPO_ROOT="${SCRIPT_DIR}"
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

TARGET="${SCRIPT_DIR}/.env"
TEMPLATE="${REPO_ROOT}/.env.example"
[ -f "${TEMPLATE}" ] || TEMPLATE="${SCRIPT_DIR}/env.example"
[ -f "${TEMPLATE}" ] || die "template not found (expected .env.example near this script)"

if [ "${ENV_MODE}" = "prod" ]; then
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prod.yml"
else
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
fi

# --- an existing .env: refuse (idempotency rule), keep (--up), or --force ---
WRITE_ENV=1
if [ -f "${TARGET}" ]; then
  if [ "${FORCE}" = "1" ]; then
    echo "WARNING: --force regenerating ${TARGET}" >&2
    echo "  If the stack has run before, keep the old secrets and change them deliberately instead." >&2
  elif [ "${UP}" = "1" ]; then
    note "${TARGET} exists — keeping it (secrets survive re-runs); bringing the stack up"
    WRITE_ENV=0
  else
    die "${TARGET} already exists — secrets are generated once. Re-read it, pass --up to start the stack with it, or pass --force to regenerate (WARNING: breaks issued JWTs and, against an existing hera-db-data volume, the DB passwords no longer match)."
  fi
fi

# --- prod needs digests: a release manifest (--pin) or a pulled tag ----------
if [ "${WRITE_ENV}" = "1" ] && [ "${ENV_MODE}" = "prod" ] && [ -z "${PIN}" ] && [ -z "${CHANNEL}" ]; then
  if command -v docker >/dev/null 2>&1; then
    CHANNEL="stable"
    note "no --pin/--channel given — pinning the rolling 'stable' tag (pass --pin vX.Y.Z for an exact release)"
  else
    die "--env prod needs image digests: pass --pin vX.Y.Z (release manifest, no docker needed) or --channel stable|beta (pulls the tag; needs docker)"
  fi
fi

API_DIGEST=""; WEB_DIGEST=""; PG_DIGEST=""; RD_DIGEST=""; CD_DIGEST=""
check_digest() {
  echo "$2" | grep -qE '^[a-f0-9]{64}$' || die "$1 missing or not a sha256 hex digest ($3)"
}

# --- optional: pin every image digest from a release manifest ---------------
if [ "${WRITE_ENV}" = "1" ] && [ -n "${PIN}" ]; then
  need_bin curl "--pin needs curl to fetch the release manifest"
  URL="https://github.com/${REPO}/releases/download/${PIN}/images.env"
  echo "fetching digest manifest ${PIN} …"
  MANIFEST="$(curl -fsSL "${URL}")" || die "could not fetch ${URL} (does the release exist?)"
  digest_of() {
    printf '%s\n' "${MANIFEST}" | sed -n "s/^$1=sha256://p; s/^$1=//p" | head -n1
  }
  API_DIGEST="$(digest_of HERA_API_DIGEST)"
  WEB_DIGEST="$(digest_of HERA_WEB_DIGEST)"
  PG_DIGEST="$(digest_of HERA_POSTGRES_DIGEST)"
  RD_DIGEST="$(digest_of HERA_REDIS_DIGEST)"
  CD_DIGEST="$(digest_of HERA_CADDY_DIGEST)"
  for pair in "HERA_API_DIGEST:${API_DIGEST}" "HERA_WEB_DIGEST:${WEB_DIGEST}" \
              "HERA_POSTGRES_DIGEST:${PG_DIGEST}" "HERA_REDIS_DIGEST:${RD_DIGEST}" \
              "HERA_CADDY_DIGEST:${CD_DIGEST}"; do
    check_digest "${pair%%:*}" "${pair#*:}" "in the manifest"
  done
  echo "pinned ${PIN}: api ${API_DIGEST:0:12}… web ${WEB_DIGEST:0:12}…"
fi

# --- optional: pin from the rolling channel tag (pull, then read RepoDigests) -
# The pull is needed anyway; repo@digest pins survive tag re-pointing, which
# is exactly what a rolling tag does on every release.
if [ "${WRITE_ENV}" = "1" ] && [ -n "${CHANNEL}" ]; then
  need_bin docker "--channel pulls images, which needs docker (use --pin to avoid it)"
  pulled_digest() {
    docker pull --quiet "$1" >/dev/null 2>&1 || return 1
    docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null | sed 's/^.*@sha256://'
  }
  echo "pulling ${API_IMAGE}:${CHANNEL} (and friends) …"
  API_DIGEST="$(pulled_digest "${API_IMAGE}:${CHANNEL}")" || die "cannot pull ${API_IMAGE}:${CHANNEL} — was a ${CHANNEL} release published? (GitHub → Actions → release) If the GHCR package is private: docker login ghcr.io"
  WEB_DIGEST="$(pulled_digest "${WEB_IMAGE}:${CHANNEL}")" || die "cannot pull ${WEB_IMAGE}:${CHANNEL}"
  PG_DIGEST="$(pulled_digest "${POSTGRES_TAG}")" || die "cannot pull ${POSTGRES_TAG}"
  RD_DIGEST="$(pulled_digest "${REDIS_TAG}")" || die "cannot pull ${REDIS_TAG}"
  CD_DIGEST="$(pulled_digest "${CADDY_TAG}")" || die "cannot pull ${CADDY_TAG}"
  for pair in "HERA_API_DIGEST:${API_DIGEST}" "HERA_WEB_DIGEST:${WEB_DIGEST}" \
              "HERA_POSTGRES_DIGEST:${PG_DIGEST}" "HERA_REDIS_DIGEST:${RD_DIGEST}" \
              "HERA_CADDY_DIGEST:${CD_DIGEST}"; do
    check_digest "${pair%%:*}" "${pair#*:}" "from docker image inspect"
  done
  echo "pinned channel ${CHANNEL}: api ${API_DIGEST:0:12}… web ${WEB_DIGEST:0:12}…"
fi

if [ "${WRITE_ENV}" = "1" ]; then
  # --- generate every secret (CSPRNG; 64 hex chars for the JWT key) ---------
  echo "generating secrets …"
  HERA_SECRET_KEY="$(hex 32)"
  POSTGRES_PASSWORD="$(hex 16)"
  DB_APP_PASSWORD="$(hex 16)"
  DB_MIGRATE_PASSWORD="$(hex 16)"
  DB_BACKUP_PASSWORD="$(hex 16)"
  REDIS_PASSWORD="$(hex 16)"
  ADMIN_PASSWORD="$(hex 12)"

  # --- start from the template, minus the keys this script manages ----------
  # Managed keys are deleted (active OR commented — some appear twice) and
  # re-appended exactly once, so the file can never carry duplicate definitions.
  MANAGED=(
    HERA_ENV HERA_DOMAIN HERA_SECRET_KEY HERA_VERSION
    HERA_ADMIN_EMAIL HERA_ADMIN_PASSWORD HERA_HTTP_PORT ACME_EMAIL
    HERA_CORS_ORIGINS HERA_TRUSTED_HOSTS HERA_PUBLIC_BASE_URL
    POSTGRES_PASSWORD HERA_DB_APP_PASSWORD HERA_DB_MIGRATE_PASSWORD HERA_DB_BACKUP_PASSWORD
    REDIS_PASSWORD REDIS_URL
    HERA_API_IMAGE HERA_WEB_IMAGE
    HERA_API_DIGEST HERA_WEB_DIGEST HERA_POSTGRES_DIGEST HERA_REDIS_DIGEST HERA_CADDY_DIGEST
  )
  DELETE_EXPRS=()
  for key in "${MANAGED[@]}"; do
    DELETE_EXPRS+=(-e "/^#?[[:space:]]*${key}=/d")
  done

  # The one version line (ADR-016 §2): read from VERSION at the repo root so
  # deploy/.env carries the real number while no committed file does.
  HERA_VERSION_VALUE=""
  if [ -f "${REPO_ROOT}/VERSION" ]; then
    HERA_VERSION_VALUE="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
  fi
  [ -n "${HERA_VERSION_VALUE}" ] \
    || note "WARNING: no VERSION file at ${REPO_ROOT} — images will be labelled 'dev'"

  TMP="$(mktemp "${TARGET}.tmp.XXXXXX")"
  trap 'rm -f "${TMP}"' EXIT
  sed -E "${DELETE_EXPRS[@]}" "${TEMPLATE}" > "${TMP}"

  # --- re-append the managed block -------------------------------------------
  cat >> "${TMP}" <<EOF

# ---------------------------------------------------------------------------
# Managed by deploy/install.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)) — generated
# secrets, GHCR images, derived allowlists. Do not duplicate these keys above.
# ---------------------------------------------------------------------------

# --- Core
HERA_ENV=${ENV_MODE}
HERA_VERSION=${HERA_VERSION_VALUE}
HERA_DOMAIN=${DOMAIN:-localhost}
HERA_SECRET_KEY=${HERA_SECRET_KEY}
# Used only by the scripted bootstrap (hera-bench setup-site, CI). The /setup
# wizard asks for the Administrator in the browser and ignores these.
HERA_ADMIN_EMAIL=${ADMIN_EMAIL}
HERA_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF

  if [ -n "${HTTP_PORT}" ]; then
    echo "HERA_HTTP_PORT=${HTTP_PORT}" >> "${TMP}"
  fi

  if [ "${ENV_MODE}" = "prod" ]; then
    cat >> "${TMP}" <<EOF
ACME_EMAIL=${ACME_EMAIL:-ops@${DOMAIN}}
HERA_PUBLIC_BASE_URL=https://${DOMAIN}
HERA_CORS_ORIGINS=https://${DOMAIN}
HERA_TRUSTED_HOSTS=${DOMAIN},127.0.0.1,hera-api
EOF
  fi

  cat >> "${TMP}" <<EOF

# --- Postgres (three least-privilege roles; see postgres/init-roles.sh)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
HERA_DB_APP_PASSWORD=${DB_APP_PASSWORD}
HERA_DB_MIGRATE_PASSWORD=${DB_MIGRATE_PASSWORD}
HERA_DB_BACKUP_PASSWORD=${DB_BACKUP_PASSWORD}

# --- Redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=redis://:${REDIS_PASSWORD}@hera-redis:6379/0

# --- Images (GHCR — decision 2026-08-30; digests pinned by ${PIN:+--pin ${PIN}}${CHANNEL:+--channel ${CHANNEL}}${PIN:-${CHANNEL:-<none>}})
HERA_API_IMAGE=${API_IMAGE}
HERA_WEB_IMAGE=${WEB_IMAGE}
HERA_API_DIGEST=${API_DIGEST}
HERA_WEB_DIGEST=${WEB_DIGEST}
HERA_POSTGRES_DIGEST=${PG_DIGEST}
HERA_REDIS_DIGEST=${RD_DIGEST}
HERA_CADDY_DIGEST=${CD_DIGEST}
EOF

  chmod 600 "${TMP}"
  mv "${TMP}" "${TARGET}"
  trap - EXIT

  # --- report ------------------------------------------------------------------
  echo ""
  echo "wrote ${TARGET}  (mode: ${ENV_MODE}, images: GHCR, pin: ${PIN:-${CHANNEL:-none}})"
  echo ""
  echo "  The first Administrator is created in the browser by the /setup wizard."
  echo "  (Scripted alternative, CI: hera-bench setup-site — uses HERA_ADMIN_EMAIL=${ADMIN_EMAIL}"
  echo "   and the one-time HERA_ADMIN_PASSWORD written to ${TARGET}.)"
  echo ""
fi

if [ "${ENV_MODE}" = "prod" ]; then
  SITE_URL="https://${DOMAIN}"
else
  PORT_IN_ENV="$(sed -n 's|^HERA_HTTP_PORT=\([0-9][0-9]*\).*|\1|p' "${TARGET}" | tail -n 1)"
  SITE_URL="http://localhost:${PORT_IN_ENV:-8080}"
fi

if [ "${UP}" = "0" ]; then
  if [ "${ENV_MODE}" = "prod" ]; then
    echo "next (on the VM, DNS for ${DOMAIN} pointing at it, 80/443 open):"
    echo "  docker compose -f ${COMPOSE_FILE} pull"
    echo "  docker compose -f ${COMPOSE_FILE} up -d --wait"
  else
    echo "next (trial on this machine):"
    echo "  docker compose -f ${COMPOSE_FILE} up -d --wait"
  fi
  echo "  then open ${SITE_URL} — a fresh site opens the /setup wizard:"
  echo "  Administrator, company, currency, timezone (MFA enrolment follows in prod)."
  echo "  (or re-run this script with --up to do both)"
  echo ""
  echo "payment provider keys are NOT env concerns: set them in the wizard or per company in the desk."
fi

# --- optional: write a transferable deploy bundle ----------------------------
if [ -n "${BUNDLE_DIR}" ]; then
  mkdir -p "${BUNDLE_DIR}/postgres"
  cp "${SCRIPT_DIR}/docker-compose.prod.yml" "${BUNDLE_DIR}/"
  cp "${SCRIPT_DIR}/Caddyfile.prod" "${BUNDLE_DIR}/"
  cp "${SCRIPT_DIR}/postgres/init-roles.sh" "${BUNDLE_DIR}/postgres/"
  cp "${TEMPLATE}" "${BUNDLE_DIR}/env.example"
  cp "${TARGET}" "${BUNDLE_DIR}/.env"
  cp "${BASH_SOURCE[0]}" "${BUNDLE_DIR}/install.sh" 2>/dev/null || true
  chmod +x "${BUNDLE_DIR}/postgres/init-roles.sh" "${BUNDLE_DIR}/install.sh" 2>/dev/null || true
  echo ""
  echo "bundle written to ${BUNDLE_DIR}: docker-compose.prod.yml, Caddyfile.prod,"
  echo "postgres/init-roles.sh, env.example, .env, install.sh — copy the directory to the VM and:"
  echo "  docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d --wait"
  echo "  (or: ./install.sh --env prod --domain ${DOMAIN:-<domain>} --up)"
fi

# --- optional: bring the stack up and point at the wizard --------------------
if [ "${UP}" = "1" ]; then
  need_bin docker "--up needs Docker Engine with the Compose plugin (ADR-005)"
  docker compose version >/dev/null 2>&1 || die "--up needs the Docker Compose plugin (ADR-005)"
  COMPOSE=(docker compose -f "${COMPOSE_FILE}")
  if [ "${ENV_MODE}" = "prod" ]; then
    echo "pulling pinned images …"
    "${COMPOSE[@]}" pull --quiet
  else
    echo "starting the stack (the first build can take a few minutes) …"
  fi
  if ! "${COMPOSE[@]}" up -d --wait; then
    echo ""
    echo "!!! the stack did not come up healthy — last logs of the services that"
    echo "!!! own first boot (one-shot migrations, api, database):"
    echo ""
    for service in migrate api db; do
      echo "---------------- ${service} ----------------"
      "${COMPOSE[@]}" logs --tail 60 "${service}" 2>/dev/null || true
      echo ""
    done
    echo "hints:"
    echo "  - 'migrate exited (1)' above is the real error; the api cannot start"
    echo "    until migrations complete."
    echo "  - a database volume from an earlier failed install can fail migrations;"
    echo "    a site that was never set up can be wiped safely:"
    echo "        ${COMPOSE[*]} down -v --remove-orphans"
    echo "    …then run this script again with --up."
    exit 1
  fi
  echo ""
  echo "Hera is up. Open the desk to finish setup:"
  echo "  -> ${SITE_URL}"
  echo "     A fresh site opens the /setup wizard: create the Administrator, name the"
  echo "     company, pick currency + timezone (and optionally provider keys) — then sign in."
  if command -v curl >/dev/null 2>&1; then
    status="$(curl -fsS "${SITE_URL}/api/v1/setup/status" 2>/dev/null || true)"
    [ -n "${status}" ] && echo "  -> setup status: ${status}"
  fi
  echo ""
  echo "operations (from $(dirname "${COMPOSE_FILE}")):"
  echo "  ${COMPOSE[*]} logs -f api     # follow the API"
  echo "  ${COMPOSE[*]} down            # stop (keep data)"
  echo "  ${COMPOSE[*]} down -v         # stop and WIPE the site"
fi
