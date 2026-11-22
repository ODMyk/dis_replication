import { Pool, PoolConfig } from "pg";

export interface NodeConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password?: string;
  max?: number;
}

export class DatabaseCluster {
  public leaderPool: Pool;
  public follower1Pool: Pool;
  public follower2Pool: Pool;
  public leaderConfig: NodeConfig;

  constructor(leaderConf?: Partial<NodeConfig>, f1Conf?: Partial<NodeConfig>, f2Conf?: Partial<NodeConfig>) {
    this.leaderConfig = {
      host: leaderConf?.host || process.env.PG_LEADER_HOST || "127.0.0.1",
      port: leaderConf?.port || Number(process.env.PG_LEADER_PORT || 5432),
      database: leaderConf?.database || "notes_a",
      user: leaderConf?.user || "repl_admin",
      password: leaderConf?.password || "repl_password_a",
      max: 20
    };

    const follower1Config: NodeConfig = {
      host: f1Conf?.host || process.env.PG_FOLLOWER1_HOST || "127.0.0.1",
      port: f1Conf?.port || Number(process.env.PG_FOLLOWER1_PORT || 5433),
      database: f1Conf?.database || "notes_a",
      user: f1Conf?.user || "repl_admin",
      password: f1Conf?.password || "repl_password_a",
      max: 20
    };

    const follower2Config: NodeConfig = {
      host: f2Conf?.host || process.env.PG_FOLLOWER2_HOST || "127.0.0.1",
      port: f2Conf?.port || Number(process.env.PG_FOLLOWER2_PORT || 5434),
      database: f2Conf?.database || "notes_a",
      user: f2Conf?.user || "repl_admin",
      password: f2Conf?.password || "repl_password_a",
      max: 20
    };

    this.leaderPool = new Pool(this.leaderConfig as PoolConfig);
    this.follower1Pool = new Pool(follower1Config as PoolConfig);
    this.follower2Pool = new Pool(follower2Config as PoolConfig);
  }

  public async switchLeader(newHost: string, newPort: number) {
    console.log(`[DatabaseCluster] Switching leader pointer to ${newHost}:${newPort}`);
    await this.leaderPool.end().catch(() => {});
    this.leaderConfig.host = newHost;
    this.leaderConfig.port = newPort;
    this.leaderPool = new Pool(this.leaderConfig as PoolConfig);
  }

  public async getLeaderCurrentLSN(): Promise<string> {
    const res = await this.leaderPool.query("SELECT pg_current_wal_lsn() as lsn;");
    return res.rows[0].lsn;
  }

  public async getFollowerReplayLSN(follower: 1 | 2 = 1): Promise<string> {
    const pool = follower === 1 ? this.follower1Pool : this.follower2Pool;
    const res = await pool.query("SELECT COALESCE(pg_last_wal_replay_lsn(), '0/0') as lsn;");
    return res.rows[0].lsn;
  }

  public async compareLSN(lsnA: string, lsnB: string): Promise<number> {
    const res = await this.leaderPool.query("SELECT pg_wal_lsn_diff($1, $2) as diff;", [lsnA, lsnB]);
    return Number(res.rows[0].diff);
  }

  public async getReplicationStats() {
    const res = await this.leaderPool.query(`
      SELECT 
        application_name, 
        client_addr, 
        state, 
        sync_state, 
        sent_lsn, 
        write_lsn, 
        flush_lsn, 
        replay_lsn,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes
      FROM pg_stat_replication;
    `);
    return res.rows;
  }

  public async closeAll() {
    await Promise.all([
      this.leaderPool.end().catch(() => {}),
      this.follower1Pool.end().catch(() => {}),
      this.follower2Pool.end().catch(() => {})
    ]);
  }
}

