CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',
  attempts     INT         NOT NULL DEFAULT 0,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error   TEXT,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (run_at)
  WHERE status = 'pending';
