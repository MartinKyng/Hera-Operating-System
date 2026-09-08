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
#   ./deploy/install.sh --env prod --domain books.example.com --http-port 8080 --https-port 8443 --up
#                                                # move the proxy off host 80/443 when
#                                                # something else already holds them
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
# init) for the pinned version into ./hera-os first. With --up it checks that
# the host ports the proxy needs are free BEFORE pulling images (a conflict
# there is the most common first-boot failure on a machine that already runs
# nginx or a second stack), then runs `docker compose up -d --wait` — the
# one-shot `migrate` service brings the schema to head before the api starts —
# and prints the /setup wizard URL, where the first Administrator, company,
# currency and timezone are created. If `up` fails, it reads the container
# states and the daemon's error and names the actual cause; only a failed
# migration is a database problem, so only that suggests wiping volumes.
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
  # The header comment IS the help text. Printing it up to the end of the
  # comment block (rather than a hard-coded line range) keeps adding a line
  # up there from silently truncating the help — '2,29p' used to stop
  # mid-sentence in the idempotency rule.
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" \
    | sed -e '/^set -euo pipefail/d' -e 's/^# \{0,1\}//'
  exit 0
}

die() { echo "install.sh: error: $*" >&2; exit 1; }
note() { echo "install.sh: $*" >&2; }

need_bin() { command -v "$1" >/dev/null 2>&1 || die "$2"; }

hex() { openssl rand -hex "$1"; }

# env_value KEY DEFAULT [FILE] — the value a KEY has in an env file. The LAST
# definition wins because this script appends its managed block, which is also
# how Docker Compose reads a file with a key twice.
env_value() {
  local value=""
  [ -f "${3:-${TARGET}}" ] \
    && value="$(sed -n "s|^[[:space:]]*$1=\([^[:space:]#]*\).*|\1|p" "${3:-${TARGET}}" | tail -n 1)"
  printf '%s' "${value:-$2}"
}

# set_env_key KEY VALUE [FILE] — replace KEY in place, or append it. Reserved
# for keys that are NOT secrets (the host ports): changing them on a re-run
# must not require --force, because --force regenerates every secret and that
# is exactly what the idempotency rule forbids.
set_env_key() {
  local key="$1" value="$2" file="${3:-${TARGET}}" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "${file}"; then
    sed -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" "${file}" > "${tmp}"
  else
    { cat "${file}"; printf '\n%s=%s\n' "${key}" "${value}"; } > "${tmp}"
  fi
  chmod 600 "${tmp}"
  mv "${tmp}" "${file}"
}

ENV_MODE="dev"
DOMAIN=""
ADMIN_EMAIL="admin@local.test"
HTTP_PORT=""
HTTPS_PORT=""
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
    --https-port) HTTPS_PORT="${2:?}"; shift 2 ;;
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
for flag in "--http-port:${HTTP_PORT}" "--https-port:${HTTPS_PORT}"; do
  value="${flag#*:}"
  [ -z "${value}" ] || printf '%s' "${value}" | grep -qE '^[0-9][0-9]*$' \
    || die "${flag%%:*} must be a port number (got '${value}')"
done
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
    HERA_ADMIN_EMAIL HERA_ADMIN_PASSWORD HERA_HTTP_PORT HERA_HTTPS_PORT ACME_EMAIL
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

  # --- host ports the proxy publishes -----------------------------------------
  # Written explicitly (not left to the Compose defaults) so deploy/.env says
  # what the stack will bind — the port preflight and the messages below read
  # these values back. prod is 80/443 because Caddy's automatic HTTPS answers
  # the ACME HTTP-01 challenge on 80; dev is 8080 (localhost trial).
  if [ "${ENV_MODE}" = "prod" ]; then
    cat >> "${TMP}" <<EOF
HERA_HTTP_PORT=${HTTP_PORT:-80}
HERA_HTTPS_PORT=${HTTPS_PORT:-443}
EOF
  else
    echo "HERA_HTTP_PORT=${HTTP_PORT:-8080}" >> "${TMP}"
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

# --- --http-port/--https-port against an existing .env -----------------------
# The ports live in deploy/.env, and a re-run keeps that file (the idempotency
# rule protects the secrets in it). The ports are not secrets, so they are
# updated in place — without this, the very remedy the port preflight suggests
# ("re-run with --http-port") would be silently ignored on the re-run.
if [ "${WRITE_ENV}" = "0" ]; then
  if [ -n "${HTTP_PORT}" ] && [ "$(env_value HERA_HTTP_PORT '')" != "${HTTP_PORT}" ]; then
    set_env_key HERA_HTTP_PORT "${HTTP_PORT}"
    note "HERA_HTTP_PORT=${HTTP_PORT} in ${TARGET} (secrets untouched)"
  fi
  if [ -n "${HTTPS_PORT}" ] && [ "$(env_value HERA_HTTPS_PORT '')" != "${HTTPS_PORT}" ]; then
    set_env_key HERA_HTTPS_PORT "${HTTPS_PORT}"
    note "HERA_HTTPS_PORT=${HTTPS_PORT} in ${TARGET} (secrets untouched)"
  fi
fi

# --- the host ports this stack will publish ----------------------------------
# Read back from the env file (the one just written, or the one kept from an
# earlier run) so everything below — the preflight, the messages — talks about
# the ports Compose will actually bind, not about hard-coded ones.
if [ "${ENV_MODE}" = "prod" ]; then
  HOST_HTTP_PORT="$(env_value HERA_HTTP_PORT 80)"
  HOST_HTTPS_PORT="$(env_value HERA_HTTPS_PORT 443)"
  PUBLISHED_PORTS=("${HOST_HTTP_PORT}" "${HOST_HTTPS_PORT}")
else
  HOST_HTTP_PORT="$(env_value HERA_HTTP_PORT 8080)"
  HOST_HTTPS_PORT=""
  PUBLISHED_PORTS=("${HOST_HTTP_PORT}")
fi

if [ "${ENV_MODE}" = "prod" ]; then
  SITE_URL="https://${DOMAIN}"
else
  SITE_URL="http://localhost:${HOST_HTTP_PORT}"
fi

if [ "${UP}" = "0" ]; then
  if [ "${ENV_MODE}" = "prod" ]; then
    echo "next (on the VM, DNS for ${DOMAIN} pointing at it, ${HOST_HTTP_PORT}/${HOST_HTTPS_PORT} open):"
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

# --- host port checks --------------------------------------------------------
# The proxy is the only service that publishes host ports, and a bind conflict
# there is the most common first-boot failure on a real VM (nginx or apache
# from the host, a second Hera stack, a previous site). Docker only reports it
# at the very end of `up -d --wait`, after every image has been pulled, and it
# reads like an infrastructure mystery: "driver failed programming external
# connectivity … address already in use". So it is checked first, in the first
# second, before ten minutes of pulls that can never start.
tcp_port_busy() { # PORT — 0 when something answers on 127.0.0.1:PORT
  (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

port_holders() { # PORT — "id|name|ports" for each container publishing it
  docker ps --no-trunc --filter "publish=$1" --format '{{.ID}}|{{.Names}}|{{.Ports}}' 2>/dev/null || true
}

own_container_ids() { # every container id of THIS compose project
  "${COMPOSE[@]}" ps -aq 2>/dev/null | tr '\n' ' ' || true
}

preflight_host_ports() {
  local port holders id name ports mine foreign
  mine="$(own_container_ids)"
  for port in "${PUBLISHED_PORTS[@]}"; do
    tcp_port_busy "${port}" || continue
    holders="$(port_holders "${port}")"
    foreign=""
    while IFS='|' read -r id name ports; do
      [ -n "${id:-}" ] || continue
      case " ${mine} " in *" ${id} "*) continue ;; esac
      foreign="${foreign}      ${name}  (${ports})"$'\n'
    done <<< "${holders}"
    if [ -z "${foreign}" ] && [ -n "${holders}" ]; then
      # Only this stack's own proxy holds it (a re-run of --up). `up -d`
      # recreates that container, which releases the bind first — not a
      # conflict, and refusing here would break the idempotent re-run.
      # (holders empty means no container has it: something on the host does.)
      note "host port ${port} is published by this stack's own proxy — it will be recreated"
      continue
    fi
    echo "" >&2
    echo "install.sh: error: host port ${port} is already in use — the proxy (Caddy)" >&2
    echo "  cannot bind it, so the stack cannot come up." >&2
    if [ -n "${holders}" ]; then
      echo "  Another container is publishing it:" >&2
      printf '%s' "${foreign}" >&2
    else
      echo "  A process on the host (not a container) is listening on it:" >&2
      echo "      sudo ss -ltnp 'sport = :${port}'" >&2
    fi
    echo "" >&2
    echo "  Stop that listener and re-run, or move Hera onto free host ports:" >&2
    echo "      ${SELF_INVOCATION} ${ENV_ARGS}${PORT_FLAG_HINT} --up" >&2
    if [ "${ENV_MODE}" = "prod" ]; then
      echo "  (Caddy's automatic HTTPS answers the ACME HTTP-01 challenge on port 80:" >&2
      echo "   on any other port it needs your own TLS proxy in front of it, or DNS-01.)" >&2
    fi
    echo "  Nothing was started and no volume was touched — this is a host port" >&2
    echo "  conflict, not a database problem." >&2
    exit 1
  done
}

# --- post-mortem: name the actual cause --------------------------------------
# `up -d --wait` fails for reasons that need opposite remedies — a migration
# that errored (fix the schema; a never-used site may be wiped), an image the
# registry refused (log in, or re-pin), a healthcheck that never turned green
# (read the logs, re-run — it resumes), or a host port someone else holds
# (stop them; the data is untouched). Answering all of them with "migrations
# failed, run down -v" is wrong three times out of four and destructive on a
# site that already has books in it, so the cause is read from the container
# states and the daemon's own error text.
container_detail() { # NAME — status|exit|error|health
  docker inspect --format \
    '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Error}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$1" 2>/dev/null || true
}

diagnose_failure() { # UP_LOG
  local up_log="$1" states line service name detail status exit_code error health
  local cause="unknown" culprit="" blob="" migrate_exit="" log_out
  local -a failed=()

  states="$("${COMPOSE[@]}" ps -a --format '{{.Service}}|{{.Name}}|{{.State}}' 2>/dev/null || true)"
  echo ""
  echo "!!! the stack did not come up healthy."
  echo ""
  echo "  service states:"
  if [ -n "${states}" ]; then
    while IFS='|' read -r service name state; do
      [ -n "${service:-}" ] || continue
      status=""; exit_code=""; error=""; health="none"
      detail="$(container_detail "${name}")"
      if [ -n "${detail}" ]; then
        status="${detail%%|*}"; detail="${detail#*|}"
        exit_code="${detail%%|*}"; detail="${detail#*|}"
        error="${detail%|*}"; health="${detail##*|}"
        blob="${blob} ${error}"
        [ "${service}" = "migrate" ] && migrate_exit="${exit_code}"
      else
        status="${state}"
      fi
      line=""
      case "${status}" in
        running)
          case "${health}" in
            healthy) line="running (healthy)" ;;
            starting) line="running (healthcheck still starting)" ;;
            none) line="running" ;;
            *) line="RUNNING BUT UNHEALTHY"; failed+=("${service}") ;;
          esac ;;
        exited)
          if [ "${exit_code}" = "0" ]; then
            line="exited 0 (one-shot: success)"
          else
            line="EXITED ${exit_code}"; failed+=("${service}")
          fi ;;
        created) line="created — never started"; failed+=("${service}") ;;
        *) line="${status}"; failed+=("${service}") ;;
      esac
      printf '    %-10s %s\n' "${service}" "${line}"
      [ -n "${error}" ] && printf '    %-10s   %s\n' "" "${error}"
    done <<< "${states}"
  else
    echo "    (no containers were created — the failure happened before any started)"
  fi
  blob="${blob} $(cat "${up_log}" 2>/dev/null)"

  # --- classify, most specific first ----------------------------------------
  # Two daemon wordings, depending on which path hit the conflict:
  #   libnetwork:   failed to bind host port 0.0.0.0:80/tcp: address already in use
  #   userland proxy: listen tcp4 0.0.0.0:80: bind: address already in use
  culprit="$(printf '%s\n' "${blob}" | sed -n \
    -e 's/.*failed to bind host port [0-9.]*:\([0-9][0-9]*\)\/.*/\1/p' \
    -e 's/.*listen tcp[46]*[[:space:]]\[*[0-9a-fA-F:.]*\]*:\([0-9][0-9]*\): bind: address already in use.*/\1/p' \
    | head -n 1)"
  if printf '%s' "${blob}" | grep -qi 'address already in use'; then
    cause="port"
  elif [ -n "${migrate_exit}" ] && [ "${migrate_exit}" != "0" ]; then
    cause="migrate"
  elif printf '%s' "${blob}" | grep -qiE 'pull access denied|denied: |unauthorized|authentication required|manifest unknown|no matching manifest|failed to resolve reference|image does not exist locally'; then
    cause="image"
  elif [ "${#failed[@]}" -gt 0 ]; then
    cause="crash"
  elif printf '%s' "${blob}" | grep -qiE 'unhealthy|dependency failed to start'; then
    cause="unhealthy"
  fi

  echo ""
  echo "  cause: $(
    case "${cause}" in
      port)
        if [ -n "${culprit}" ]; then
          echo "host port ${culprit} is already in use — the proxy cannot bind it"
        else
          echo "a host port the proxy publishes (${PUBLISHED_PORTS[*]}) is already in use"
        fi ;;
      migrate) echo "the one-shot migrate service failed; api and worker wait on it" ;;
      image) echo "an image could not be pulled" ;;
      crash) echo "${failed[*]:-a service} exited non-zero" ;;
      unhealthy) echo "a container started but never passed its healthcheck in time" ;;
      *) echo "not one of the known causes — the logs below are the evidence" ;;
    esac
  )"

  # --- logs: the implicated services first, then the first-boot owners -------
  local -a log_services=(${failed[@]+"${failed[@]}"})
  case "${cause}" in
    port) add_log_service proxy ;;
    image) : ;; # nothing ran; the pull error above is the whole story
    *)
      add_log_service proxy
      for service in migrate api db; do add_log_service "${service}"; done ;;
  esac
  if [ "${#log_services[@]}" -gt 0 ]; then
    echo ""
    echo "!!! last logs of the services involved:"
    echo ""
  fi
  for service in ${log_services[@]+"${log_services[@]}"}; do
    echo "---------------- ${service} ----------------"
    # Capture rather than stream: an empty log is itself information (the
    # service never got far enough to write one), and only the capture can
    # tell the two apart.
    log_out="$("${COMPOSE[@]}" logs --tail 60 "${service}" 2>/dev/null || true)"
    if [ -n "${log_out}" ]; then
      printf '%s\n' "${log_out}"
    else
      echo "(no output — this service never got far enough to log anything)"
    fi
    echo ""
  done

  echo "hints:"
  case "${cause}" in
    port)
      echo "  - this is a host port conflict, not a schema or data problem: no volume"
      echo "    was written. Do NOT run 'down -v' for it."
      echo "  - see what holds the port:"
      echo "        sudo ss -ltnp 'sport = :${culprit:-80}'"
      echo "        docker ps --filter publish=${culprit:-80}"
      echo "    (on a shared VM it is usually nginx/apache, or a second Hera stack —"
      echo "     'docker compose ls' lists them)"
      echo "  - stop it and re-run, or move Hera onto free host ports:"
      echo "        ${SELF_INVOCATION} ${ENV_ARGS}${PORT_FLAG_HINT} --up"
      if [ "${ENV_MODE}" = "prod" ]; then
        echo "    (Caddy's automatic HTTPS answers the ACME HTTP-01 challenge on port 80;"
        echo "     on another port it needs your own TLS proxy in front, or DNS-01.)"
      fi
      ;;
    migrate)
      echo "  - 'migrate' exited non-zero above: that is the real error. api and worker"
      echo "    declare depends_on migrate service_completed_successfully, so they"
      echo "    cannot start until it does."
      echo "  - a database volume from an earlier failed install can fail migrations;"
      echo "    a site that was never set up can be wiped safely:"
      echo "        ${COMPOSE[*]} down -v --remove-orphans"
      echo "    …then run this script again with --up. A site WITH data cannot: read"
      echo "    the migration error above and fix it, or restore a backup."
      ;;
    image)
      echo "  - the pinned image is not reachable from this machine. GHCR packages"
      echo "    default to private, so first: docker login ghcr.io (a token with"
      echo "    Packages: read)."
      echo "  - then check the pin: https://github.com/${REPO}/releases"
      echo "    and re-run with a tag that exists (--pin vX.Y.Z)."
      ;;
    crash)
      echo "  - the logs above belong to the service(s) that exited; everything else"
      echo "    was waiting on them. Fix that cause and re-run — 'up -d --wait'"
      echo "    resumes rather than recreating healthy containers."
      ;;
    unhealthy)
      echo "  - every container started, but one never turned healthy inside its"
      echo "    start_period. A small VM is slow on a cold first boot: read the logs"
      echo "    above, then re-run this script with --up (it waits again, it does not"
      echo "    rebuild anything)."
      ;;
    *)
      echo "  - the state table and logs above are the evidence; nothing matched a"
      echo "    known first-boot failure."
      ;;
  esac
  echo "  - full state: ${COMPOSE[*]} ps -a"
  echo "  - follow one: ${COMPOSE[*]} logs -f <service>"
}

add_log_service() { # SERVICE — append to the caller's log_services unless listed
  local existing
  for existing in ${log_services[@]+"${log_services[@]}"}; do
    [ "${existing}" = "$1" ] && return 0
  done
  log_services+=("$1")
  return 0
}

# How this script was invoked, for the re-run lines in the messages above.
if [ "${STANDALONE}" = "1" ]; then
  SELF_INVOCATION="curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s --"
else
  SELF_INVOCATION="${SCRIPT_DIR}/install.sh"
fi
ENV_ARGS="--env ${ENV_MODE}${DOMAIN:+ --domain ${DOMAIN}}"
if [ "${ENV_MODE}" = "prod" ]; then
  PORT_FLAG_HINT=" --http-port <free> --https-port <free>"
else
  PORT_FLAG_HINT=" --http-port <free>"
fi

# --- optional: bring the stack up and point at the wizard --------------------
if [ "${UP}" = "1" ]; then
  need_bin docker "--up needs Docker Engine with the Compose plugin (ADR-005)"
  docker compose version >/dev/null 2>&1 || die "--up needs the Docker Compose plugin (ADR-005)"
  COMPOSE=(docker compose -f "${COMPOSE_FILE}")

  preflight_host_ports

  if [ "${ENV_MODE}" = "prod" ]; then
    echo "pulling pinned images …"
    if ! "${COMPOSE[@]}" pull --quiet; then
      echo ""
      echo "!!! could not pull the pinned images (nothing was started)."
      echo "  - GHCR packages default to private, so first: docker login ghcr.io"
      echo "    (a token with Packages: read)."
      echo "  - then check the pin against https://github.com/${REPO}/releases and"
      echo "    re-run with a release that exists (--pin vX.Y.Z)."
      exit 1
    fi
  else
    echo "starting the stack (the first build can take a few minutes) …"
  fi

  UP_LOG="$(mktemp "${TMPDIR:-/tmp}/hera-install-up.XXXXXX")"
  trap 'rm -f "${UP_LOG}"' EXIT
  set +e
  "${COMPOSE[@]}" up -d --wait 2>&1 | tee "${UP_LOG}"
  UP_STATUS="${PIPESTATUS[0]}"
  set -e
  if [ "${UP_STATUS}" -ne 0 ]; then
    diagnose_failure "${UP_LOG}"
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
