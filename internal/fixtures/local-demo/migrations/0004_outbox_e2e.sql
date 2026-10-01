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

CREATE TABLE IF NOT EXISTS outbox_e2e_domain (
  id  TEXT PRIMARY KEY,
  seq INT  NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox_e2e_effects (
  effect_id TEXT PRIMARY KEY
);
