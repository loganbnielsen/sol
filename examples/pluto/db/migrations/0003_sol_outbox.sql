CREATE TABLE IF NOT EXISTS sol_outbox (
  id            BIGSERIAL   PRIMARY KEY,
  kind          TEXT        NOT NULL,
  aggregate_key TEXT        NOT NULL,
  ord           BIGINT      NOT NULL,
  payload       TEXT        NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS sol_outbox_key_ord_idx
  ON sol_outbox (aggregate_key, ord);
