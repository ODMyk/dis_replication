#!/usr/bin/env bash
# Experiment 4: Leader Failover
# Kills pg-leader-a, promotes pg-follower-a1, measures downtime + lost acks
set -euo pipefail

LEADER_CONTAINER="pg-leader-a"
FOLLOWER_CONTAINER="pg-follower-a1"
FOLLOWER_IP="172.28.1.2"
NETWORK="pg-replication-lab_net_conf_a"
DB="notes_a"
USER="repl_admin"
WORK_DIR="/home/dmyko/Projects/distibuted-info-systems/task-5-replication"

echo "=== Experiment 4: Leader Failover ==="
echo "Start time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cd $WORK_DIR

# Ensure async mode
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "ALTER SYSTEM SET synchronous_standby_names = '';" 2>/dev/null || true
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c "SELECT pg_reload_conf();" 2>/dev/null || true

# Baseline counts
LEADER_COUNT_BEFORE=$(docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
FOLLOWER_COUNT_BEFORE=$(docker exec -i $FOLLOWER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
echo "Leader rows before: $LEADER_COUNT_BEFORE"
echo "Follower rows before: $FOLLOWER_COUNT_BEFORE"

# Wait for follower to fully catch up
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -c \
  "SELECT client_addr, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Start load generator (indefinite) in background
echo "Starting load generator (120 req/s, 120s)..."
cd service
LOAD_RATE=120 LOAD_DURATION=120 node --import=tsx/esm src/load-generator.ts 2>&1 | \
  tee /tmp/exp4_load.log &
LOAD_PID=$!
echo "Load PID: $LOAD_PID"
cd $WORK_DIR

# Count journal entries before kill
sleep 5  # let load warm up and generate some entries
JOURNAL_BEFORE=$(wc -l < service/writes_journal.ndjson 2>/dev/null || echo 0)
echo "Journal entries before kill: $JOURNAL_BEFORE"

# KILL THE LEADER
KILL_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
KILL_EPOCH=$(date -u +%s)
docker kill $LEADER_CONTAINER
echo "[$KILL_TS] Leader killed!"

# Count how many journal acks came in between start and kill
sleep 1
JOURNAL_AT_KILL=$(wc -l < service/writes_journal.ndjson 2>/dev/null || echo 0)
echo "Journal entries at kill: $JOURNAL_AT_KILL"
NEW_ACKS=$((JOURNAL_AT_KILL - JOURNAL_BEFORE))
echo "New acks since load started: $NEW_ACKS"

# Check follower immediately after leader death
sleep 2
FOLLOWER_COUNT_AFTER_KILL=$(docker exec -i $FOLLOWER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
echo "Follower rows immediately after leader kill: $FOLLOWER_COUNT_AFTER_KILL"

# Stop load generator (it'll error on leader, but journal has the acks)
kill $LOAD_PID 2>/dev/null || true
wait $LOAD_PID 2>/dev/null || true

# PROMOTE follower-a1 to new leader
PROMOTE_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PROMOTE_EPOCH=$(date -u +%s)
docker exec -i $FOLLOWER_CONTAINER su-exec postgres pg_ctl promote -D /var/lib/postgresql/data
echo "[$PROMOTE_TS] Promoted pg-follower-a1 to leader!"

DOWNTIME=$((PROMOTE_EPOCH - KILL_EPOCH))
echo "Approximate downtime: ${DOWNTIME}s"

sleep 3

# Verify new leader is writable
NEW_LEADER_STATUS=$(docker exec -i $FOLLOWER_CONTAINER psql -U $USER -d $DB -t -c "SELECT pg_is_in_recovery();" | tr -d ' ')
NEW_LEADER_COUNT=$(docker exec -i $FOLLOWER_CONTAINER psql -U $USER -d $DB -t -c "SELECT count(*) FROM notes;" | tr -d ' ')
echo "New leader pg_is_in_recovery(): $NEW_LEADER_STATUS (should be 'f')"
echo "New leader row count: $NEW_LEADER_COUNT"

# Calculate lost acks
# Journal has ack'd writes, compare with what's on the new leader
echo "--- Checking for lost acks ---"
JOURNAL_TOTAL=$(wc -l < service/writes_journal.ndjson 2>/dev/null || echo 0)
echo "Total journal entries: $JOURNAL_TOTAL"
echo "Rows on new leader: $NEW_LEADER_COUNT"

# Check if any journal IDs are missing from the new leader
echo "Running verify_consistency for lost acks..."
uv run --with "psycopg[binary]" scripts/verify_consistency.py \
  --nodes "127.0.0.1:5433:${DB}:${USER}:repl_password_a:new-leader-a1" \
  --journal service/writes_journal.ndjson 2>&1 | tail -20 || true

echo ""
echo "=== FAILOVER RESULTS ==="
echo "Kill time: $KILL_TS"
echo "Promote time: $PROMOTE_TS"
echo "Downtime: ${DOWNTIME}s"
echo "Leader rows before: $LEADER_COUNT_BEFORE"
echo "New leader rows after: $NEW_LEADER_COUNT"
echo "Journal entries: $JOURNAL_TOTAL"

# Restart old leader — it should come back as standby (recovery mode)
echo ""
echo "--- Restarting old leader (pg-leader-a) ---"
docker compose up -d pg-leader-a 2>&1 | tail -5 || true
sleep 10
docker exec -i $LEADER_CONTAINER psql -U $USER -d $DB -t -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d ' ' || \
  echo "Old leader not accepting connections (expected in recovery)"

echo "=== END Exp4 === $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

