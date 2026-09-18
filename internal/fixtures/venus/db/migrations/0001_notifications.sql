CREATE TABLE IF NOT EXISTS notifications (
  charge_id    TEXT        PRIMARY KEY,
  amount_cents INT         NOT NULL,
  customer_id  TEXT        NOT NULL,
  currency     TEXT        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
)
