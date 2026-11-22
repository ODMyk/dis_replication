-- Configuration B1 Leader init script
CREATE TABLE IF NOT EXISTS notes (
    id BIGSERIAL PRIMARY KEY,
    author_id VARCHAR(64) NOT NULL,
    title VARCHAR(255) NOT NULL,
    body TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notes_author_id ON notes(author_id);
CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at);

-- Set replica identity to DEFAULT (using primary key id)
ALTER TABLE notes REPLICA IDENTITY DEFAULT;

-- Ensure repl_admin has replication rights
ALTER ROLE repl_admin WITH REPLICATION;

-- Create publication for table notes
CREATE PUBLICATION pub_notes_b1 FOR TABLE notes;

