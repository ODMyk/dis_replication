import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";

export interface JournalRecord {
  id: number;
  ack_timestamp_ms: number;
  operation: "INSERT" | "UPDATE" | "DELETE";
  payload_hash: string;
}

export class Journal {
  private filePath: string;
  private writeStream: fs.WriteStream | null = null;

  constructor(filePath?: string) {
    this.filePath = filePath || path.join(process.cwd(), "writes_journal.ndjson");
  }

  public open() {
    this.writeStream = fs.createWriteStream(this.filePath, { flags: "a", encoding: "utf-8" });
  }

  public static hashPayload(author_id: string, title: string, body: string): string {
    return crypto.createHash("sha256").update(`${author_id}:${title}:${body}`).digest("hex");
  }

  public record(id: number, operation: "INSERT" | "UPDATE" | "DELETE", payload_hash: string): JournalRecord {
    const entry: JournalRecord = {
      id,
      ack_timestamp_ms: Date.now(),
      operation,
      payload_hash
    };
    if (this.writeStream) {
      this.writeStream.write(JSON.stringify(entry) + "\n");
    } else {
      fs.appendFileSync(this.filePath, JSON.stringify(entry) + "\n", "utf-8");
    }
    return entry;
  }

  public close(): Promise<void> {
    return new Promise((resolve) => {
      if (this.writeStream) {
        this.writeStream.end(() => resolve());
      } else {
        resolve();
      }
    });
  }

  public getFilePath(): string {
    return this.filePath;
  }
}

