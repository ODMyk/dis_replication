#!/usr/bin/env bash
# Experiment 3: WAL disconnect test
# Usage: bash scripts/exp3_disconnect.sh <duration_seconds> <label>
# Example: bash scripts/exp3_disconnect.sh 300 "5min"
set -euo pipefail

DURATION=${1:-300}
LABEL=${2:-"test"}
FOLLOWER_CONTAINER="pg-follower-a1"
FOLLOWER_IP="172.28.1.3"
LEADER_CONTAINER="pg-leader-a"
NETWORK="pg-replication-lab_net_conf_a"
LEADER_PORT=5432
FOLLOWER_PORT=5433
DB="notes_a"
USER="repl_admin"

echo "=== Experiment 3: WAL Disconnect (${LABEL}, ${DURATION}s) ==="
echo "Start time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Baseline row count and WAL position
COUNT_BEFORE=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
LSN_BEFORE=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT pg_current_wal_lsn();" | tr -d ' ')
echo "Rows before disconnect: $COUNT_BEFORE"
echo "LSN before disconnect: $LSN_BEFORE"

# Check follower lag at baseline
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "SELECT client_addr, state, sync_state, replay_lsn, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Start load generator in background (120 req/s for duration + buffer)
LOAD_DURATION=$((DURATION + 60))
echo "Starting load generator: 120 req/s for ${LOAD_DURATION}s..."
cd /home/dmyko/Projects/distibuted-info-systems/task-5-replication/service
LOAD_RATE=120 LOAD_DURATION=$LOAD_DURATION node --import=tsx/esm src/load-generator.ts 2>&1 | \
  tee /tmp/exp3_load_${LABEL}.log &
LOAD_PID=$!
echo "Load generator PID: $LOAD_PID"
cd /home/dmyko/Projects/distibuted-info-systems/task-5-replication

sleep 3  # let load warm up

# DISCONNECT follower
DISCONNECT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DISCONNECT_EPOCH=$(date -u +%s)
docker network disconnect $NETWORK $FOLLOWER_CONTAINER
echo "[$DISCONNECT_TS] Disconnected $FOLLOWER_CONTAINER"

# Wait for the specified duration
echo "Waiting ${DURATION}s..."
sleep $DURATION

# Check how many rows accumulated on leader
COUNT_AFTER=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
LSN_AFTER=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT pg_current_wal_lsn();" | tr -d ' ')
WAL_DIFF=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c \
  "SELECT pg_wal_lsn_diff('${LSN_AFTER}', '${LSN_BEFORE}');" | tr -d ' ')
ACCUMULATED=$((COUNT_AFTER - COUNT_BEFORE))
echo "Rows accumulated during disconnect: $ACCUMULATED (leader total: $COUNT_AFTER)"
echo "WAL accumulated (bytes): $WAL_DIFF"

# Check replication slot status (before reconnect)
echo "--- Replication slot status (before reconnect) ---"
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "SELECT slot_name, active, wal_status, safe_wal_size, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes FROM pg_replication_slots;"

# RECONNECT follower
RECONNECT_EPOCH=$(date -u +%s)
RECONNECT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker network connect $NETWORK $FOLLOWER_CONTAINER
echo "[$RECONNECT_TS] Reconnected $FOLLOWER_CONTAINER"

# Poll until caught up
echo "Polling for catchup..."
CATCHUP_START=$RECONNECT_EPOCH
while true; do
  sleep 2
  LAG=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c \
    "SELECT coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::text, 'no_replica') FROM pg_stat_replication WHERE client_addr='${FOLLOWER_IP}';" 2>/dev/null | tr -d ' \r\n' || echo "no_replica")
  NOW=$(date -u +%s)
  ELAPSED=$((NOW - CATCHUP_START))
  echo "  [+${ELAPSED}s] Lag: $LAG bytes"
  if [ "$LAG" = "no_replica" ]; then
    echo "  Follower not yet connected, waiting..."
    continue
  fi
  if [ "$LAG" -le 100 ] 2>/dev/null; then
    echo "  CAUGHT UP!"
    break
  fi
  if [ $ELAPSED -gt 300 ]; then
    echo "  Catchup timeout after 300s!"
    break
  fi
done

CATCHUP_EPOCH=$(date -u +%s)
CATCHUP_TIME=$((CATCHUP_EPOCH - RECONNECT_EPOCH))
TOTAL_DISCONNECT_TIME=$((RECONNECT_EPOCH - DISCONNECT_EPOCH))

echo ""
echo "=== EXPERIMENT 3 RESULTS (${LABEL}) ==="
echo "Disconnect duration (actual): ${TOTAL_DISCONNECT_TIME}s"
echo "Rows accumulated: $ACCUMULATED"
echo "WAL accumulated: $WAL_DIFF bytes"
echo "Catchup time: ${CATCHUP_TIME}s"

# Stop load generator
kill $LOAD_PID 2>/dev/null || true
wait $LOAD_PID 2>/dev/null || true

# Final consistency check
echo ""
echo "--- Final row counts ---"
LEADER_COUNT=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
FOLLOWER_COUNT=$(docker exec -i $FOLLOWER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" 2>/dev/null | tr -d ' ' || echo "ERROR")
echo "Leader: $LEADER_COUNT"
echo "Follower-a1: $FOLLOWER_COUNT"
echo "Match: $([ "$LEADER_COUNT" = "$FOLLOWER_COUNT" ] && echo YES || echo NO)"

echo ""
echo "=== END ${LABEL} === $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

