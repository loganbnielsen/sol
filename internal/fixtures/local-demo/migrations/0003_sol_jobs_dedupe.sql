ALTER TABLE sol_jobs ADD COLUMN IF NOT EXISTS dedupe_key TEXT;
ALTER TABLE sol_jobs ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
  ON sol_jobs (workspace, kind, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS sol_jobs_terminal_idx
  ON sol_jobs (finished_at)
  WHERE status <> 'pending';
