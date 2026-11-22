import { DatabaseCluster } from "./db.js";
import { Journal } from "./journal.js";

interface GeneratorOptions {
  targetRate: number; // requests per second (e.g. 100 or 120)
  durationSec?: number; // 0 or undefined for indefinite
  reportIntervalSec?: number;
}

export class LoadGenerator {
  private cluster: DatabaseCluster;
  private journal: Journal;
  private isRunning: boolean = false;
  private counter: number = 0;
  private ackCount: number = 0;
  private errorCount: number = 0;

  constructor(cluster: DatabaseCluster, journal: Journal) {
    this.cluster = cluster;
    this.journal = journal;
  }

  public async start(options: GeneratorOptions): Promise<void> {
    const { targetRate, durationSec, reportIntervalSec = 5 } = options;
    this.isRunning = true;
    this.journal.open();

    console.log(`[LoadGenerator] Started with target rate: ${targetRate} req/s`);
    if (durationSec) {
      console.log(`[LoadGenerator] Duration: ${durationSec} seconds`);
    } else {
      console.log(`[LoadGenerator] Running indefinitely until stopped.`);
    }

    const intervalMs = 1000 / targetRate;
    const startTime = Date.now();
    let lastReportTime = Date.now();
    let lastAckCount = 0;

    // Report ticker
    const reportTimer = setInterval(() => {
      const now = Date.now();
      const deltaSec = (now - lastReportTime) / 1000;
      const deltaAcks = this.ackCount - lastAckCount;
      const currentRate = deltaAcks / deltaSec;
      const totalElapsed = ((now - startTime) / 1000).toFixed(1);

      console.log(
        `[LoadGenerator ${new Date().toISOString()}] Elapsed: ${totalElapsed}s | Total Acks: ${this.ackCount} | Errors: ${this.errorCount} | Current Rate: ${currentRate.toFixed(1)} req/s`
      );

      lastReportTime = now;
      lastAckCount = this.ackCount;
    }, reportIntervalSec * 1000);

    // Write worker
    const writeNext = async () => {
      if (!this.isRunning) return;

      const idx = ++this.counter;
      const author_id = `user_${(idx % 1000) + 1}`;
      const title = `Load Note #${idx} - ${Date.now()}`;
      const body = `Automated load payload record ${idx} generated at ${new Date().toISOString()}`;
      const payloadHash = Journal.hashPayload(author_id, title, body);

      try {
        const res = await this.cluster.leaderPool.query(
          `INSERT INTO notes (author_id, title, body, updated_at) VALUES ($1, $2, $3, NOW()) RETURNING id;`,
          [author_id, title, body]
        );
        const noteId = Number(res.rows[0].id);
        this.journal.record(noteId, "INSERT", payloadHash);
        this.ackCount++;
      } catch (err: any) {
        this.errorCount++;
        // Keep going even on transient error (e.g. during failover or disconnect)
      }
    };

    // Schedule writes at steady targetRate
    const loopTimer = setInterval(() => {
      if (!this.isRunning) {
        clearInterval(loopTimer);
        return;
      }
      writeNext();
    }, intervalMs);

    // Stop condition if durationSec is specified
    if (durationSec && durationSec > 0) {
      await new Promise<void>((resolve) => {
        setTimeout(async () => {
          this.stop();
          clearInterval(loopTimer);
          clearInterval(reportTimer);
          resolve();
        }, durationSec * 1000);
      });
    }
  }

  public stop() {
    this.isRunning = false;
    console.log(`[LoadGenerator] Stopped. Total Acknowledged Writes: ${this.ackCount}, Total Errors: ${this.errorCount}`);
  }

  public getStats() {
    return {
      ackCount: this.ackCount,
      errorCount: this.errorCount,
      totalAttempted: this.counter
    };
  }
}

// Standalone runner
if (import.meta.url === `file://${process.argv[1]}`) {
  const cluster = new DatabaseCluster();
  const journal = new Journal();

  const rate = Number(process.env.LOAD_RATE || 120);
  const duration = process.env.LOAD_DURATION ? Number(process.env.LOAD_DURATION) : undefined;

  const generator = new LoadGenerator(cluster, journal);

  process.on("SIGINT", async () => {
    console.log("\n[LoadGenerator] Received SIGINT. Shutting down...");
    generator.stop();
    await journal.close();
    await cluster.closeAll();
    process.exit(0);
  });

  process.on("SIGTERM", async () => {
    console.log("\n[LoadGenerator] Received SIGTERM. Shutting down...");
    generator.stop();
    await journal.close();
    await cluster.closeAll();
    process.exit(0);
  });

  generator.start({ targetRate: rate, durationSec: duration }).then(async () => {
    if (duration) {
      await journal.close();
      await cluster.closeAll();
      process.exit(0);
    }
  });
}

