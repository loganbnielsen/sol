-- sol:disposition expand

CREATE TABLE IF NOT EXISTS orders_ts (
  order_id     TEXT        PRIMARY KEY,
  item         TEXT        NOT NULL,
  quantity     INTEGER     NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'accepted',
  accepted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  fulfilled_at TIMESTAMPTZ,
  confirmed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS fulfilled_orders_ts (
  order_id       TEXT        PRIMARY KEY,
  item           TEXT        NOT NULL,
  quantity       INTEGER     NOT NULL,
  correlation_id TEXT        NOT NULL,
  fulfilled_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_confirmations_ts (
  order_id     TEXT        PRIMARY KEY,
  confirmed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
