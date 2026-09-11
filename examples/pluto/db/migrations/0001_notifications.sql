CREATE TABLE IF NOT EXISTS pluto_notifications (
  id           BIGSERIAL    PRIMARY KEY,
  charge_id    TEXT         NOT NULL,
  customer_id  TEXT         NOT NULL,
  amount_cents INTEGER      NOT NULL,
  currency     TEXT         NOT NULL DEFAULT 'usd',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
