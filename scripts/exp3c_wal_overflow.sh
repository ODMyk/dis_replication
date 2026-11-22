#!/usr/bin/env bash
# Experiment 3c: WAL slot overflow test
# Sets max_slot_wal_keep_size=32MB, generates enough writes to overflow, checks slot invalidation
set -euo pipefail

FOLLOWER_CONTAINER="pg-follower-a1"
FOLLOWER_IP="172.28.1.2"
LEADER_CONTAINER="pg-leader-a"
NETWORK="pg-replication-lab_net_conf_a"
DB="notes_a"
USER="repl_admin"
SLOT="slot_follower_a1"

echo "=== Experiment 3c: WAL Slot Overflow ==="
echo "Start time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Set tight WAL limit
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "ALTER SYSTEM SET max_slot_wal_keep_size = '32MB';"
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c "SELECT pg_reload_conf();"
echo "Set max_slot_wal_keep_size = 32MB"

# Disconnect follower
DISCONNECT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker network disconnect $NETWORK $FOLLOWER_CONTAINER 2>/dev/null || true
echo "[$DISCONNECT_TS] Disconnected $FOLLOWER_CONTAINER"

# Check slot status at start
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "SELECT slot_name, active, wal_status, safe_wal_size, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes FROM pg_replication_slots WHERE slot_name='${SLOT}';"

echo "Generating heavy writes to overflow 32MB WAL limit..."
# Heavy inserts: much larger body to fill WAL faster
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "INSERT INTO notes(author_id, title, body)
   SELECT 'wal_overflow_test', 'WAL Fill ' || gs, repeat('X', 4000)
   FROM generate_series(1, 10000) gs;" &

# Poll slot status every 5s for up to 120s
OVERFLOW_DETECTED=false
for i in $(seq 1 24); do
  sleep 5
  STATUS=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c \
    "SELECT wal_status FROM pg_replication_slots WHERE slot_name='${SLOT}';" | tr -d ' ')
  LAG=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c \
    "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots WHERE slot_name='${SLOT}';" 2>/dev/null | tr -d ' ' || echo "?")
  echo "[+$((i*5))s] Slot status: $STATUS, lag: $LAG bytes"
  if [ "$STATUS" = "lost" ] || [ "$STATUS" = "unreserved" ]; then
    echo "OVERFLOW DETECTED: slot status = $STATUS"
    OVERFLOW_DETECTED=true
    break
  fi
done

wait 2>/dev/null || true

echo "--- Final slot status ---"
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "SELECT slot_name, active, wal_status, safe_wal_size, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes FROM pg_replication_slots WHERE slot_name='${SLOT}';"

if [ "$OVERFLOW_DETECTED" = "true" ]; then
  echo "RESULT: Replication slot INVALIDATED due to WAL overflow"
  echo "Recovery requires: pg_basebackup on follower to resync from scratch"
  echo "Slot lost — WAL already recycled past follower's replay point"
else
  echo "RESULT: Slot still valid (32MB not yet overflowed in test period)"
fi

# Reconnect follower to observe reconnection behavior
docker network connect $NETWORK $FOLLOWER_CONTAINER 2>/dev/null || true
sleep 5
echo "--- Follower logs after reconnect ---"
docker logs $FOLLOWER_CONTAINER 2>&1 | grep -iE "(ERROR|FATAL|requested|invalid|conflict|stream|basebackup)" | tail -15

# Reset WAL limit to unlimited
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "ALTER SYSTEM SET max_slot_wal_keep_size = -1;"
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c "SELECT pg_reload_conf();"
echo "Reset max_slot_wal_keep_size = -1 (unlimited)"

echo "=== END Exp3c === $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

