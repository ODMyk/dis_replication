#!/bin/sh
set -e

echo "[Leader Init] Initializing Leader database notes_a..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE TABLE IF NOT EXISTS notes (
        id BIGSERIAL PRIMARY KEY,
        author_id VARCHAR(64) NOT NULL,
        title VARCHAR(255) NOT NULL,
        body TEXT NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_notes_author_id ON notes(author_id);
    CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at);

    -- Ensure repl_admin has REPLICATION privilege
    ALTER ROLE repl_admin WITH REPLICATION;

    -- Create physical replication slots for followers if not exists
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'slot_follower_a1') THEN
            PERFORM pg_create_physical_replication_slot('slot_follower_a1');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'slot_follower_a2') THEN
            PERFORM pg_create_physical_replication_slot('slot_follower_a2');
        END IF;
    END \$\$;
EOSQL

echo "[Leader Init] Setting up pg_hba.conf in PGDATA..."
cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"
chmod 600 "$PGDATA/pg_hba.conf"

echo "[Leader Init] Configuration completed successfully."
