import express, { Request, Response } from "express";
import { DatabaseCluster } from "./db.js";
import { Journal } from "./journal.js";

const app = express();
app.use(express.json());

const cluster = new DatabaseCluster();
const journal = new Journal();
journal.open();

// 1. Create a note (Writes to Leader)
app.post("/api/notes", async (req: Request, res: Response) => {
  try {
    const { author_id, title, body } = req.body;
    if (!author_id || !title || !body) {
      return res.status(400).json({ error: "Missing required fields: author_id, title, body" });
    }

    const payloadHash = Journal.hashPayload(author_id, title, body);
    const query = `
      INSERT INTO notes (author_id, title, body, updated_at)
      VALUES ($1, $2, $3, NOW())
      RETURNING id, author_id, title, body, updated_at, pg_current_wal_lsn() as lsn;
    `;
    const result = await cluster.leaderPool.query(query, [author_id, title, body]);
    const note = result.rows[0];

    // Log to write acknowledgment journal
    journal.record(Number(note.id), "INSERT", payloadHash);

    res.status(201).json({
      note: {
        id: note.id,
        author_id: note.author_id,
        title: note.title,
        body: note.body,
        updated_at: note.updated_at
      },
      write_lsn: note.lsn
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// 2. Read note by ID (Supports Follower, RAW-gate, or Leader)
app.get("/api/notes/:id", async (req: Request, res: Response) => {
  try {
    const id = Number(req.params.id);
    const mode = req.query.mode as string; // 'follower' (default), 'raw', 'leader'
    const minLsn = req.query.min_lsn as string | undefined;

    if (mode === "leader") {
      const result = await cluster.leaderPool.query("SELECT * FROM notes WHERE id = $1;", [id]);
      if (result.rows.length === 0) return res.status(404).json({ error: "Note not found" });
      return res.json({ note: result.rows[0], source: "leader" });
    }

    if (mode === "raw" && minLsn) {
      // Read-after-write with LSN-gate
      let caughtUp = false;
      const start = Date.now();
      while (Date.now() - start < 100) {
        const fLsnRes = await cluster.follower1Pool.query("SELECT COALESCE(pg_last_wal_replay_lsn(), '0/0') as lsn;");
        const replayLsn = fLsnRes.rows[0].lsn;
        const diff = await cluster.compareLSN(minLsn, replayLsn);
        if (diff <= 0) {
          caughtUp = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 2));
      }

      if (caughtUp) {
        const result = await cluster.follower1Pool.query("SELECT * FROM notes WHERE id = $1;", [id]);
        if (result.rows.length > 0) {
          return res.json({ note: result.rows[0], source: "follower-1 (lsn-gate satisfied)" });
        }
      }
      // Fallback to leader if follower hasn't caught up within gate window
      const lResult = await cluster.leaderPool.query("SELECT * FROM notes WHERE id = $1;", [id]);
      if (lResult.rows.length === 0) return res.status(404).json({ error: "Note not found" });
      return res.json({ note: lResult.rows[0], source: "leader (raw-fallback)" });
    }

    // Default: read from follower-1
    const result = await cluster.follower1Pool.query("SELECT * FROM notes WHERE id = $1;", [id]);
    if (result.rows.length === 0) {
      return res.status(404).json({ error: "Note not found on follower (may be replication lag)" });
    }
    res.json({ note: result.rows[0], source: "follower-1" });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// 3. Update note (Leader)
app.put("/api/notes/:id", async (req: Request, res: Response) => {
  try {
    const id = Number(req.params.id);
    const { title, body } = req.body;
    const result = await cluster.leaderPool.query(
      `UPDATE notes SET title = COALESCE($1, title), body = COALESCE($2, body), updated_at = NOW()
       WHERE id = $3 RETURNING *;`,
      [title, body, id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: "Note not found" });
    const note = result.rows[0];
    const payloadHash = Journal.hashPayload(note.author_id, note.title, note.body);
    journal.record(id, "UPDATE", payloadHash);
    res.json({ note });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// 4. Delete note (Leader)
app.delete("/api/notes/:id", async (req: Request, res: Response) => {
  try {
    const id = Number(req.params.id);
    const result = await cluster.leaderPool.query("DELETE FROM notes WHERE id = $1 RETURNING *;", [id]);
    if (result.rows.length === 0) return res.status(404).json({ error: "Note not found" });
    journal.record(id, "DELETE", "deleted");
    res.json({ message: "Note deleted", id });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// 5. Get notes by author (Follower)
app.get("/api/authors/:authorId/notes", async (req: Request, res: Response) => {
  try {
    const authorId = req.params.authorId;
    const result = await cluster.follower1Pool.query(
      "SELECT * FROM notes WHERE author_id = $1 ORDER BY updated_at DESC LIMIT 100;",
      [authorId]
    );
    res.json({ author_id: authorId, count: result.rows.length, notes: result.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// 6. Replication Status
app.get("/api/replication/status", async (_req: Request, res: Response) => {
  try {
    const leaderLsn = await cluster.getLeaderCurrentLSN();
    const f1Lsn = await cluster.getFollowerReplayLSN(1);
    const stats = await cluster.getReplicationStats();
    res.json({
      leader_lsn: leaderLsn,
      follower1_replay_lsn: f1Lsn,
      stats
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

const PORT = Number(process.env.PORT || 3000);
export const server = app.listen(PORT, () => {
  console.log(`[Notes API Server] Listening on http://localhost:${PORT}`);
});

process.on("SIGTERM", async () => {
  server.close(async () => {
    await journal.close();
    await cluster.closeAll();
  });
});

