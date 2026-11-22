#!/bin/bash
set -e

echo "[Conf-B Setup] Setting up bidirectional logical replication between pg-leader-b1 and pg-leader-b2..."

USER="repl_admin"
DB="notes_b"

echo "[Conf-B Setup] Waiting for pg-leader-b1 to be ready..."
until docker exec -i pg-leader-b1 pg_isready -U "$USER" -d "$DB"; do
    sleep 1
done

echo "[Conf-B Setup] Waiting for pg-leader-b2 to be ready..."
until docker exec -i pg-leader-b2 pg_isready -U "$USER" -d "$DB"; do
    sleep 1
done

echo "[Conf-B Setup] Both nodes are ready. Creating publications and subscriptions..."

# Create publication on B1 if not exists
docker exec -i pg-leader-b1 psql -U "$USER" -d "$DB" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_notes_b1') THEN
        CREATE PUBLICATION pub_notes_b1 FOR TABLE notes;
    END IF;
END \$\$;
"

# Create publication on B2 if not exists
docker exec -i pg-leader-b2 psql -U "$USER" -d "$DB" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_notes_b2') THEN
        CREATE PUBLICATION pub_notes_b2 FOR TABLE notes;
    END IF;
END \$\$;
"

# Create subscription on B1 from B2 (separate -c commands to avoid transaction block)
docker exec -i pg-leader-b1 psql -U "$USER" -d "$DB" -c "DROP SUBSCRIPTION IF EXISTS sub_from_b2;" || true
docker exec -i pg-leader-b1 psql -U "$USER" -d "$DB" -c "CREATE SUBSCRIPTION sub_from_b2 CONNECTION 'host=172.29.1.11 port=5432 user=repl_admin password=repl_password_b dbname=notes_b' PUBLICATION pub_notes_b2 WITH (origin = 'none', copy_data = false);"

# Create subscription on B2 from B1 (separate -c commands to avoid transaction block)
docker exec -i pg-leader-b2 psql -U "$USER" -d "$DB" -c "DROP SUBSCRIPTION IF EXISTS sub_from_b1;" || true
docker exec -i pg-leader-b2 psql -U "$USER" -d "$DB" -c "CREATE SUBSCRIPTION sub_from_b1 CONNECTION 'host=172.29.1.10 port=5432 user=repl_admin password=repl_password_b dbname=notes_b' PUBLICATION pub_notes_b1 WITH (origin = 'none', copy_data = false);"

echo "[Conf-B Setup] Bidirectional logical replication successfully configured!"
