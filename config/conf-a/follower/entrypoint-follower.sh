#!/bin/sh
set -e

echo "[Follower Entrypoint] Starting follower node: $NODE_ROLE..."
echo "[Follower Entrypoint] Target leader: $LEADER_HOST:$LEADER_PORT, slot: $SLOT_NAME"

export PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# Ensure PGDATA is owned by postgres
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# If data directory is not yet initialized with PostgreSQL data
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[Follower Entrypoint] PGDATA ($PGDATA) is empty. Waiting for leader $LEADER_HOST:$LEADER_PORT..."
    until PGPASSWORD="$POSTGRES_PASSWORD" pg_isready -h "$LEADER_HOST" -p "$LEADER_PORT" -U "$POSTGRES_USER" -d notes_a; do
        echo "[Follower Entrypoint] Leader not ready yet. Retrying in 2 seconds..."
        sleep 2
    done

    echo "[Follower Entrypoint] Leader is ready. Performing pg_basebackup with slot $SLOT_NAME..."
    # Ensure directory is empty
    rm -rf "$PGDATA"/*
    
    su-exec postgres env PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup \
        -h "$LEADER_HOST" \
        -p "$LEADER_PORT" \
        -U "$POSTGRES_USER" \
        -D "$PGDATA" \
        -Fp \
        -Xs \
        -R \
        -c fast \
        -S "$SLOT_NAME"

    echo "[Follower Entrypoint] Basebackup finished successfully."
    chmod 700 "$PGDATA"
    chown -R postgres:postgres "$PGDATA"
fi

echo "[Follower Entrypoint] Starting PostgreSQL server..."
exec su-exec postgres postgres -D "$PGDATA" \
    -c hot_standby=on \
    -c log_min_messages=info \
    -c log_connections=on \
    -c log_disconnections=on
