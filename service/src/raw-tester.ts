import { DatabaseCluster } from "./db.js";
import { Journal } from "./journal.js";

interface RawTestOptions {
  iterations: number;
  useRawGate: boolean;
  followerIndex: 1 | 2;
  label: string;
}

interface RawTestResult {
  label: string;
  total_iterations: number;
  stale_reads: number;
  stale_rate_percent: number;
  avg_lag_bytes: number;
  max_lag_bytes: number;
  latencies_ms: {
    min: number;
    max: number;
    avg: number;
    p50: number;
    p95: number;
    p99: number;
  };
  duration_sec: number;
}

function calculatePercentiles(sortedNumbers: number[]) {
  if (sortedNumbers.length === 0) return { min: 0, max: 0, avg: 0, p50: 0, p95: 0, p99: 0 };
  const min = sortedNumbers[0];
  const max = sortedNumbers[sortedNumbers.length - 1];
  const avg = sortedNumbers.reduce((a, b) => a + b, 0) / sortedNumbers.length;
  const p50 = sortedNumbers[Math.floor(sortedNumbers.length * 0.50)];
  const p95 = sortedNumbers[Math.floor(sortedNumbers.length * 0.95)];
  const p99 = sortedNumbers[Math.floor(sortedNumbers.length * 0.99)];
  return { min, max, avg, p50, p95, p99 };
}

export async function runRawExperiment(
  cluster: DatabaseCluster,
  journal: Journal,
  options: RawTestOptions
): Promise<RawTestResult> {
  const { iterations, useRawGate, followerIndex, label } = options;
  const followerPool = followerIndex === 1 ? cluster.follower1Pool : cluster.follower2Pool;

  console.log(`\n======================================================`);
  console.log(`Starting RAW Experiment: [${label}]`);
  console.log(`Iterations: ${iterations}, RAW Gate: ${useRawGate ? "ENABLED (LSN-gate)" : "DISABLED (Direct Follower)"}`);
  console.log(`======================================================`);

  let staleCount = 0;
  const readLatencies: number[] = [];
  let totalLagBytes = 0;
  let maxLagBytes = 0;
  let lagSamples = 0;

  const startTime = Date.now();

  for (let i = 1; i <= iterations; i++) {
    const author_id = `raw_user_${(i % 100) + 1}`;
    const title = `RAW Note #${i} - ${Date.now()}`;
    const body = `Content for test iteration ${i} with random payload ${Math.random()}`;
    const payloadHash = Journal.hashPayload(author_id, title, body);

    // 1. Write note on leader and capture write LSN
    const insertRes = await cluster.leaderPool.query(
      `INSERT INTO notes (author_id, title, body, updated_at)
       VALUES ($1, $2, $3, NOW())
       RETURNING id, pg_current_wal_lsn() as write_lsn;`,
      [author_id, title, body]
    );

    const noteId = Number(insertRes.rows[0].id);
    const writeLsn = insertRes.rows[0].write_lsn as string;

    // Record acknowledged write in client journal
    journal.record(noteId, "INSERT", payloadHash);

    // Measure replication lag periodically (every 50 iterations)
    if (i % 50 === 0) {
      try {
        const stats = await cluster.getReplicationStats();
        if (stats.length > 0 && stats[0].replay_lag_bytes !== null) {
          const lagBytes = Number(stats[0].replay_lag_bytes);
          totalLagBytes += Math.max(0, lagBytes);
          if (lagBytes > maxLagBytes) maxLagBytes = lagBytes;
          lagSamples++;
        }
      } catch (err) {
        // ignore periodic stat error
      }
    }

    // 2. Immediate read from follower
    const readStart = performance.now();
    let readRecord: any = null;

    if (useRawGate) {
      // LSN-gate implementation:
      // Check if follower has caught up to writeLsn. If not, wait briefly (up to 50ms) or fallback to leader
      let caughtUp = false;
      const gateStart = Date.now();
      while (Date.now() - gateStart < 50) {
        const lsnRes = await followerPool.query("SELECT COALESCE(pg_last_wal_replay_lsn(), '0/0') as replay_lsn;");
        const replayLsn = lsnRes.rows[0].replay_lsn;
        const diff = await cluster.compareLSN(writeLsn, replayLsn);
        if (diff <= 0) {
          caughtUp = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 1));
      }

      if (caughtUp) {
        const fRes = await followerPool.query("SELECT id, title, body FROM notes WHERE id = $1;", [noteId]);
        if (fRes.rows.length > 0) {
          readRecord = fRes.rows[0];
        }
      } else {
        // Fallback to leader to guarantee read-after-write
        const lRes = await cluster.leaderPool.query("SELECT id, title, body FROM notes WHERE id = $1;", [noteId]);
        if (lRes.rows.length > 0) {
          readRecord = lRes.rows[0];
        }
      }
    } else {
      // Direct reading from follower without any gate
      const fRes = await followerPool.query("SELECT id, title, body FROM notes WHERE id = $1;", [noteId]);
      if (fRes.rows.length > 0) {
        readRecord = fRes.rows[0];
      }
    }

    const readElapsed = performance.now() - readStart;
    readLatencies.push(readElapsed);

    // 3. Verify freshness
    if (!readRecord || readRecord.title !== title) {
      staleCount++;
    }

    if (i % 2000 === 0 || i === iterations) {
      console.log(
        `[${label}] Progress: ${i}/${iterations} | Stale reads so far: ${staleCount} (${((staleCount / i) * 100).toFixed(2)}%)`
      );
    }
  }

  const durationSec = (Date.now() - startTime) / 1000;
  readLatencies.sort((a, b) => a - b);
  const latencyStats = calculatePercentiles(readLatencies);
  const staleRate = (staleCount / iterations) * 100;
  const avgLag = lagSamples > 0 ? totalLagBytes / lagSamples : 0;

  console.log(`\n--- Completed [${label}] ---`);
  console.log(`Total iterations: ${iterations}`);
  console.log(`Stale reads: ${staleCount} (${staleRate.toFixed(3)}%)`);
  console.log(`Read latency: p50=${latencyStats.p50.toFixed(2)}ms, p95=${latencyStats.p95.toFixed(2)}ms, p99=${latencyStats.p99.toFixed(2)}ms`);
  console.log(`Duration: ${durationSec.toFixed(2)}s\n`);

  return {
    label,
    total_iterations: iterations,
    stale_reads: staleCount,
    stale_rate_percent: staleRate,
    avg_lag_bytes: avgLag,
    max_lag_bytes: maxLagBytes,
    latencies_ms: latencyStats,
    duration_sec: durationSec
  };
}

// Standalone execution entrypoint
if (import.meta.url === `file://${process.argv[1]}`) {
  const cluster = new DatabaseCluster();
  const journal = new Journal();
  journal.open();

  const iterations = Number(process.env.RAW_ITERATIONS || 10000);
  const useRawGate = process.env.USE_RAW_GATE === "true";
  const label = process.env.TEST_LABEL || (useRawGate ? "With-RAW-Gate" : "Async-No-Gate");

  runRawExperiment(cluster, journal, {
    iterations,
    useRawGate,
    followerIndex: 1,
    label
  })
    .then(async (res) => {
      console.log("FINAL_RESULT_JSON:", JSON.stringify(res));
      await journal.close();
      await cluster.closeAll();
      process.exit(0);
    })
    .catch(async (err) => {
      console.error("Experiment failed:", err);
      await journal.close();
      await cluster.closeAll();
      process.exit(1);
    });
}

