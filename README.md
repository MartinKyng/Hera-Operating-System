# Hera OS

A business operating system for Nigerian businesses — books, people, payments
and messaging in one desk. NGN-first, with Nigerian payment rails and statutory
payroll shaped for local requirements.

This repository is the **public distribution** for Hera OS: the installer, the
production Compose stack, and the release manifests. It is published
automatically from the development repository — the files here are overwritten
on every release, so do not edit them in place.

## What you get

- **Accounting** — chart of accounts, journals, sales invoices, payments,
  statements, trial balance, P&L and balance sheet. Ledgers are insert-only;
  documents move Draft → Submit → Cancel.
- **Payments** — collect on a submitted invoice through Paystack or
  Flutterwave, with signed webhooks and idempotent posting.
- **Bank** — import a settlement CSV, clear payment entries against it by
  amount and date window, work the unmatched report, move money between own
  accounts.
- **Payroll** — employees, attendance, leave, salary structures, payslips that
  post to the ledger, and payment of the run.
- **HRM, CRM, messaging, stock and assets** — the framework modules are always
  on; CRM, stock, assets and industry verticals are optional apps enabled per
  site.
- **Multi-company** — membership decides whose books a request touches; the
  desk shows and switches the active company.
- **Security** — Argon2id passwords, JWT with rotating refresh tokens, TOTP
  MFA, per-company isolation, secrets encrypted at rest.

## Production: one file, one deploy command

Prerequisites: Linux, Bash, Git, Docker Engine with Compose v2, curl and
OpenSSL. Point your domain at the host and open TCP 80/443. No application
source checkout, GitHub login, host Python/Node, or local image build is needed.

Download the **one file** once into a dedicated installation directory:

```bash
curl -fsSLo hera https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/hera
```

Then deploy with **one command**:

```bash
bash hera prod up --domain books.example.com --channel stable --acme-email ops@example.com
```

That command shallow-clones **only this public release repository**, downloads
its Compose/configuration files and optional source-free Dockerfile, generates
`deploy/.env.prod` once, resolves Docker Hub tags to immutable digests, pulls
images and starts the stack. A one-shot migration runs before the API. Open
the printed `/setup` URL to create the Administrator and company, then enrol MFA.

All container images come from **Docker Hub**. Hera API/web use
`docker.io/kyngroyalty/hera-os`, with separate `api-*` / `web-*` tags. PostgreSQL,
Redis and Caddy use Docker Hub official images. Other registries are rejected,
including in saved env files, shell overrides and downloaded manifests.

For an exact release, replace `--channel stable` with `--pin vX.Y.Z` (use an
actual published tag). The release must include this new CLI bundle; older
bundles fail before any images are pulled. `--channel beta` selects public
`dev` and Docker Hub beta tags. Development still needs the authorized source
checkout; the public distribution cannot build a development site.

## Re-run, operate and upgrade

Run from the same directory, using the same environment/project overrides:

```bash
bash hera prod up                        # keep secrets and pinned versions
bash hera prod doctor
bash hera logs prod api --tail 100 --no-follow
bash hera backup prod
bash hera prod update --channel stable   # or --pin vX.Y.Z
```

`prod update` fetches a fresh public bundle and updates image references without
regenerating secrets. The bundle pointer changes only after a successful
command. Previous bundle trees and timestamped env backups remain available;
this is **not automatic database rollback**. Back up and verify restores before
upgrading. Never use installer `--force` or `prod up --fresh` for an upgrade.

Local state lives in `deploy/.env.prod`; release files live under
`.hera-releases/`, selected by `.hera-release`. Secrets and Docker data volumes
are outside the public clone. Preserve the installation directory, env file,
attachments and verified database backups. Do not delete release trees still
used by running containers' bind mounts. Only one operator should deploy at a time.

Existing deployments must retain their exact Compose project and env file.
Use `HERA_PROD_PROJECT` and an absolute `HERA_PROD_ENV_FILE` when migrating an
older flat-bundle install. Do not guess the project name: that creates a new
set of volumes instead of opening the existing site.

## Legacy installer compatibility

The earlier entry remains available for existing automation:

```bash
curl -fsSL https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/install.sh \
  | bash -s -- --env prod --domain books.example.com --channel stable --up
```

New installations should use `hera` for both deployment and subsequent operations.
The legacy flat installer has a different file layout; do not mix layouts or
regenerate its secrets when adopting the CLI.

## Public files

- `hera` — production bootstrap and operations CLI
- `install.sh`, `deploy/install.sh` — compatible environment generator
- `deploy/docker-compose.prod.yml` — prebuilt images; no build/source mounts
- `deploy/Caddyfile.prod`, `deploy/postgres/init-roles.sh` — runtime configuration
- `deploy/Dockerfile` — optional digest-only image wrapper; **not used by Compose**
- `.env.example`, `VERSION`, `LICENSE`, `README.md`, `docs/onboarding.md`
- Each release attaches `images.env`, containing repositories and five digests.

No application code or application-building Dockerfiles are published here.
Changes to these files arrive through the release publisher, not manual edits.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).
