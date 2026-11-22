#!/usr/bin/env bash
# Experiment 5: Config B — Multi-Leader Bidirectional Replication & Conflicts
set -uo pipefail

WORK_DIR="/home/dmyko/Projects/distibuted-info-systems/task-5-replication"
B1="pg-leader-b1"
B2="pg-leader-b2"
NETWORK="pg-replication-lab_net_conf_b"
DB="notes_b"
USER="repl_admin"

echo "=== Experiment 5: Config B — Multi-Leader Conflicts Test ==="
echo "Start time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Clean up table on both nodes
echo "--- Cleaning up table notes on B1 and B2 ---"
docker exec -i $B1 psql -U $USER -d $DB -c "TRUNCATE TABLE notes RESTART IDENTITY;"
sleep 3
docker exec -i $B2 psql -U $USER -d $DB -c "TRUNCATE TABLE notes RESTART IDENTITY;" 2>/dev/null || true
docker exec -i $B2 psql -U $USER -d $DB -c "ALTER SEQUENCE notes_id_seq RESTART WITH 1;" 2>/dev/null || true
docker exec -i $B1 psql -U $USER -d $DB -c "ALTER SEQUENCE notes_id_seq RESTART WITH 1;" 2>/dev/null || true

# Seed 3 initial notes on B1
echo "--- Seeding 3 initial notes on B1 ---"
docker exec -i $B1 psql -U $USER -d $DB -c \
  "INSERT INTO notes(author_id,title,body) VALUES
   ('user1','Initial Note 1','original body 1'),
   ('user2','Initial Note 2','original body 2'),
   ('user3','Initial Note 3','original body 3')
   RETURNING id, title;"

# Wait for replication to B2
sleep 5
echo "--- Verifying initial replication on B2 ---"
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT id, author_id, title FROM notes ORDER BY id;"

# On B2, sync sequence so local inserts start at id 4
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT setval('notes_id_seq', 3);"

echo ""
echo "--- [NETWORK PARTITION] Disconnecting B2 from network ---"
DISCONNECT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker network disconnect $NETWORK $B2
echo "[$DISCONNECT_TS] pg-leader-b2 disconnected"
sleep 2

echo ""
echo "=========================================================="
echo "SCENARIO 1: Concurrent UPDATE on same row (id=1)"
echo "=========================================================="
docker exec -i $B1 psql -U $USER -d $DB -c \
  "UPDATE notes SET title='Title-FROM-B1', updated_at=NOW() WHERE id=1; SELECT id,title,updated_at FROM notes WHERE id=1;"
docker exec -i $B2 psql -U $USER -d $DB -c \
  "UPDATE notes SET title='Title-FROM-B2', updated_at=NOW() WHERE id=1; SELECT id,title,updated_at FROM notes WHERE id=1;"

echo ""
echo "=========================================================="
echo "SCENARIO 2: Concurrent INSERT on both nodes"
echo "  Case A: ID Collision (both try to use id=10 explicitly or sequence collision)"
echo "  Case B: Normal concurrent INSERT with different IDs"
echo "=========================================================="
# Case A: Explicit ID collision test to demonstrate replication failure
docker exec -i $B1 psql -U $USER -d $DB -c \
  "INSERT INTO notes(id, author_id, title, body) VALUES(10, 'author_b1', 'Note ID 10 from B1', 'body b1');"
docker exec -i $B2 psql -U $USER -d $DB -c \
  "INSERT INTO notes(id, author_id, title, body) VALUES(10, 'author_b2', 'Note ID 10 from B2 (COLLISION)', 'body b2');"
echo "Both nodes inserted row with id=10"

# Case B: Different IDs
docker exec -i $B1 psql -U $USER -d $DB -c \
  "INSERT INTO notes(id, author_id, title, body) VALUES(101, 'author_b1', 'Unique B1 Note', 'body b1');"
docker exec -i $B2 psql -U $USER -d $DB -c \
  "INSERT INTO notes(id, author_id, title, body) VALUES(202, 'author_b2', 'Unique B2 Note', 'body b2');"
echo "B1 inserted id=101, B2 inserted id=202"

echo ""
echo "=========================================================="
echo "SCENARIO 3: DELETE on B1, UPDATE on B2 for same row (id=2)"
echo "=========================================================="
docker exec -i $B1 psql -U $USER -d $DB -c "DELETE FROM notes WHERE id=2;"
docker exec -i $B2 psql -U $USER -d $DB -c \
  "UPDATE notes SET body='Updated on B2 while B1 deleted it', updated_at=NOW() WHERE id=2; SELECT id,body FROM notes WHERE id=2;"

echo ""
echo "--- State on B1 during partition ---"
docker exec -i $B1 psql -U $USER -d $DB -c "SELECT id, author_id, title, body FROM notes ORDER BY id;"
echo "--- State on B2 during partition ---"
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT id, author_id, title, body FROM notes ORDER BY id;"

echo ""
echo "--- [HEAL PARTITION] Reconnecting B2 with static IP 172.29.1.11 ---"
docker network connect --ip 172.29.1.11 $NETWORK $B2
RECONNECT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$RECONNECT_TS] Reconnected B2"

echo "Waiting 15 seconds for logical replication to process backlog..."
sleep 15

echo ""
echo "=========================================================="
echo "POST-RECONNECTION ANALYSIS"
echo "=========================================================="

echo "--- B1 Notes Table ---"
docker exec -i $B1 psql -U $USER -d $DB -c "SELECT id, author_id, title, left(body, 35) as body, updated_at FROM notes ORDER BY id;"

echo "--- B2 Notes Table ---"
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT id, author_id, title, left(body, 35) as body, updated_at FROM notes ORDER BY id;"

echo ""
echo "--- Subscription Status on B1 ---"
docker exec -i $B1 psql -U $USER -d $DB -c "SELECT subname, subenabled FROM pg_subscription;"
docker exec -i $B1 psql -U $USER -d $DB -c "SELECT * FROM pg_stat_subscription;"

echo "--- Subscription Status on B2 ---"
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT subname, subenabled FROM pg_subscription;"
docker exec -i $B2 psql -U $USER -d $DB -c "SELECT * FROM pg_stat_subscription;"

echo ""
echo "--- PostgreSQL Error Logs on B1 (Replication worker errors) ---"
docker logs $B1 2>&1 | grep -iE "(ERROR|conflict|duplicate key|terminating logical replication)" | tail -10 || true

echo "--- PostgreSQL Error Logs on B2 (Replication worker errors) ---"
docker logs $B2 2>&1 | grep -iE "(ERROR|conflict|duplicate key|terminating logical replication)" | tail -10 || true

echo ""
echo "=== END Experiment 5 === $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
