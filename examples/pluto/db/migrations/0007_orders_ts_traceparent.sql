-- sol:disposition expand

ALTER TABLE orders_ts ADD COLUMN IF NOT EXISTS traceparent TEXT;
