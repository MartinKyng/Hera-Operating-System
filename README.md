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

## Deploy in one command

On a VM with DNS pointing at it and ports 80/443 open:

```bash
curl -fsSL https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/install.sh \
  | bash -s -- --env prod --domain books.example.com --acme-email ops@example.com --pin v0.1.0 --up
```

That single command:

1. downloads the production stack into `./hera-os` — no `git clone` needed;
2. writes `deploy/.env` once, with every secret machine-generated;
3. pins all five images **by digest** from the release manifest, so a later
   tag re-point cannot move your deployment;
4. runs `docker compose up -d --wait` — a one-shot `migrate` service brings the
   schema to head before the API starts;
5. prints the URL of the `/setup` wizard.

Open that URL and create the first Administrator, company, currency and time
zone. Until the wizard is completed every API route answers
`409 setup_required`; afterwards it is closed for good.

### Requirements

Docker Engine with the Compose plugin (or any OCI runtime: Podman Compose,
nerdctl). Containers are the only supported runtime — there is no host install.

### Trying it locally

```bash
curl -fsSLO https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/install.sh
chmod +x install.sh && ./install.sh --up     # http://localhost:8080
```

## Releases and versioning

| Channel | Branch | Image tags | Release |
|---|---|---|---|
| **stable** | `main` | `<VERSION>`, `stable` | `v<VERSION>` |
| **beta** | `dev` | `<VERSION>-beta.<run>`, `beta` | `v<VERSION>-beta.<run>` (prerelease) |

Every release carries an `images.env` manifest listing the digest of each image
— first-party and third-party:

```bash
curl -fsSL https://github.com/MartinKyng/Hera-Operating-System/releases/download/v0.1.0/images.env
```

`--pin vX.Y.Z` reads that manifest (no Docker needed). `--channel stable|beta`
pins whatever the rolling tag currently resolves to. Digests are the safe
reference; tags are convenience.

Images are published to `ghcr.io/martinkyng/hera-os-api` and
`ghcr.io/martinkyng/hera-os-web`, and are publicly pullable without
authentication.

### Upgrading

```bash
curl -fsSL https://raw.githubusercontent.com/MartinKyng/Hera-Operating-System/main/install.sh \
  | bash -s -- --env prod --domain books.example.com --pin v0.1.1 --force
```

`--force` regenerates `deploy/.env`. If the stack has already run, keep the
existing secrets instead and update only the five `HERA_*_DIGEST` values, then:

```bash
docker compose -f deploy/docker-compose.prod.yml pull
docker compose -f deploy/docker-compose.prod.yml up -d --wait
```

## What is in this repository

```
install.sh                      the installer — the single deploy command
deploy/docker-compose.prod.yml  the production stack (Caddy, api, worker, db, redis)
deploy/Caddyfile.prod           automatic HTTPS
deploy/postgres/init-roles.sh   least-privilege Postgres roles, first boot only
.env.example                    the env template install.sh fills in
VERSION                         the version this bundle was published from
docs/onboarding.md              first boot and the /setup wizard
```

The source code is not published here.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).
