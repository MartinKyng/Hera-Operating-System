#!/bin/bash
# Least-privilege Postgres roles (roadmap §5), created on FIRST boot of the
# hera-db-data volume only — changing passwords later means resetting the
# volume or ALTER ROLE by hand.
#
#   hera_app      — runtime DML (SELECT/INSERT/UPDATE/DELETE)
#   hera_migrate  — Alembic migrations (owns the schema objects it creates)
#   hera_backup   — pg_dump reads
#
# Runs as POSTGRES_USER (hera_admin superuser) during initdb.

set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hera_app') THEN
            EXECUTE format('CREATE ROLE hera_app LOGIN PASSWORD %L', '${HERA_DB_APP_PASSWORD}');
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hera_migrate') THEN
            EXECUTE format('CREATE ROLE hera_migrate LOGIN PASSWORD %L', '${HERA_DB_MIGRATE_PASSWORD}');
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hera_backup') THEN
            EXECUTE format('CREATE ROLE hera_backup LOGIN PASSWORD %L', '${HERA_DB_BACKUP_PASSWORD}');
        END IF;
    END
    \$\$;

    GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO hera_app, hera_migrate, hera_backup;

    -- hera_migrate owns the schema and every object migrations create.
    GRANT USAGE, CREATE ON SCHEMA public TO hera_migrate;

    -- Runtime role: DML only, no DDL.
    GRANT USAGE ON SCHEMA public TO hera_app;

    -- Tables hera_migrate creates from here on are usable by the app role…
    ALTER DEFAULT PRIVILEGES FOR ROLE hera_migrate IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO hera_app;
    ALTER DEFAULT PRIVILEGES FOR ROLE hera_migrate IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO hera_app;

    -- …and readable by the backup role.
    ALTER DEFAULT PRIVILEGES FOR ROLE hera_migrate IN SCHEMA public
        GRANT SELECT ON TABLES TO hera_backup;
EOSQL

echo "hera roles ready: hera_app (DML), hera_migrate (DDL), hera_backup (read)"
