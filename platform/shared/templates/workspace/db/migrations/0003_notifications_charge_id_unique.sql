CREATE UNIQUE INDEX IF NOT EXISTS {{name}}_notifications_charge_id_idx
  ON {{name}}_notifications (charge_id);
