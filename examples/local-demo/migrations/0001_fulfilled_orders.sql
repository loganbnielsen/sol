CREATE TABLE IF NOT EXISTS fulfilled_orders (
  order_id       TEXT        PRIMARY KEY,
  item           TEXT        NOT NULL,
  quantity       INT         NOT NULL,
  correlation_id TEXT        NOT NULL,
  fulfilled_at   TIMESTAMPTZ NOT NULL DEFAULT now()
)
