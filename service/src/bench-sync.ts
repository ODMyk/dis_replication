import { DatabaseCluster } from "./db.js";
import { Journal } from "./journal.js";

interface BenchRunResult {
  run: number;
  total_writes: number;
  duration_sec: number;
  throughput_req_sec: number;
  latencies_ms: {
    min: number;
    max: number;
    avg: number;
    p50: number;
    p95: number;
    p99: number;
  };
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

export async function runWriteBenchmark(
  cluster: DatabaseCluster,
  journal: Journal,
  count: number,
  concurrency: number = 10,
  recordJournal: boolean = true
): Promise<BenchRunResult> {
  const writeLatencies: number[] = [];
  const startTime = Date.now();

  let completed = 0;
  let currentId = 0;

  async function worker(workerId: number) {
    while (true) {
      const idx = ++currentId;
      if (idx > count) break;

      const author_id = `user_${(idx % 500) + 1}`;
      const title = `Bench Note #${idx} - W${workerId}`;
      const body = `Content of note ${idx} created during write benchmark`;
      const payloadHash = Journal.hashPayload(author_id, title, body);

      const t0 = performance.now();
      const res = await cluster.leaderPool.query(
        `INSERT INTO notes (author_id, title, body, updated_at) VALUES ($1, $2, $3, NOW()) RETURNING id;`,
        [author_id, title, body]
      );
      const elapsed = performance.now() - t0;
      writeLatencies.push(elapsed);

      const noteId = Number(res.rows[0].id);
      if (recordJournal) {
        journal.record(noteId, "INSERT", payloadHash);
      }

      completed++;
      if (completed % 2500 === 0 || completed === count) {
        console.log(`Progress: ${completed}/${count} writes done...`);
      }
    }
  }

  const workers = Array.from({ length: concurrency }, (_, i) => worker(i + 1));
  await Promise.all(workers);

  const durationSec = (Date.now() - startTime) / 1000;
  writeLatencies.sort((a, b) => a - b);
  const latencyStats = calculatePercentiles(writeLatencies);
  const throughput = count / durationSec;

  return {
    run: 0,
    total_writes: count,
    duration_sec: durationSec,
    throughput_req_sec: throughput,
    latencies_ms: latencyStats
  };
}

async function main() {
  const cluster = new DatabaseCluster();
  const journal = new Journal();
  journal.open();

  const count = Number(process.env.BENCH_COUNT || 10000);
  const runsCount = Number(process.env.BENCH_RUNS || 3);
  const mode = process.env.BENCH_MODE || "async"; // 'async' or 'sync'
  const concurrency = Number(process.env.BENCH_CONCURRENCY || 10);

  console.log(`======================================================`);
  console.log(`Starting Write Benchmark: Mode = ${mode.toUpperCase()}`);
  console.log(`Writes per run: ${count}, Total runs: ${runsCount}, Concurrency: ${concurrency}`);
  console.log(`======================================================`);

  // Warmup run (1000 writes)
  console.log(`\n[Warmup] Running warmup with 1,000 writes...`);
  await runWriteBenchmark(cluster, journal, 1000, concurrency, false);
  console.log(`[Warmup] Completed.`);

  const results: BenchRunResult[] = [];
  for (let r = 1; r <= runsCount; r++) {
    console.log(`\n--- Run ${r} of ${runsCount} ---`);
    const res = await runWriteBenchmark(cluster, journal, count, concurrency, true);
    res.run = r;
    results.push(res);
    console.log(
      `Run ${r}: Duration=${res.duration_sec.toFixed(2)}s, Throughput=${res.throughput_req_sec.toFixed(1)} req/s, ` +
        `p50=${res.latencies_ms.p50.toFixed(2)}ms, p95=${res.latencies_ms.p95.toFixed(2)}ms, p99=${res.latencies_ms.p99.toFixed(2)}ms`
    );
  }

  // Calculate median p50, p95, p99 and median throughput across runs
  const p50s = results.map((r) => r.latencies_ms.p50).sort((a, b) => a - b);
  const p95s = results.map((r) => r.latencies_ms.p95).sort((a, b) => a - b);
  const p99s = results.map((r) => r.latencies_ms.p99).sort((a, b) => a - b);
  const avgs = results.map((r) => r.latencies_ms.avg).sort((a, b) => a - b);
  const tps = results.map((r) => r.throughput_req_sec).sort((a, b) => a - b);

  const medianResult = {
    mode,
    runs: runsCount,
    writes_per_run: count,
    median_throughput_req_sec: tps[Math.floor(runsCount / 2)],
    median_latencies_ms: {
      avg: avgs[Math.floor(runsCount / 2)],
      p50: p50s[Math.floor(runsCount / 2)],
      p95: p95s[Math.floor(runsCount / 2)],
      p99: p99s[Math.floor(runsCount / 2)]
    },
    raw_runs: results
  };

  console.log(`\n======================================================`);
  console.log(`BENCHMARK SUMMARY (${mode.toUpperCase()}):`);
  console.log(`Median Throughput: ${medianResult.median_throughput_req_sec.toFixed(1)} req/sec`);
  console.log(`Median Latencies: p50=${medianResult.median_latencies_ms.p50.toFixed(2)}ms, p95=${medianResult.median_latencies_ms.p95.toFixed(2)}ms, p99=${medianResult.median_latencies_ms.p99.toFixed(2)}ms`);
  console.log(`======================================================`);
  console.log("FINAL_BENCHMARK_JSON:" + JSON.stringify(medianResult));

  await journal.close();
  await cluster.closeAll();
  process.exit(0);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error("Benchmark failed:", err);
    process.exit(1);
  });
}

