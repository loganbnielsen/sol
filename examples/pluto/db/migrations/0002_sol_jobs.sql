CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  workspace    TEXT        NOT NULL,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',
  attempts     INT         NOT NULL DEFAULT 0,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error   TEXT,
  dedupe_key   TEXT,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (workspace, run_at)
  WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
  ON sol_jobs (workspace, kind, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS sol_jobs_terminal_idx
  ON sol_jobs (workspace, finished_at)
  WHERE status <> 'pending';
