CREATE TABLE IF NOT EXISTS hosted_projects (
  project_id TEXT PRIMARY KEY,
  workspace  TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS hosted_releases (
  release_id  TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES hosted_projects(project_id),
  environment TEXT NOT NULL,
  image_tag   TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'live',
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS hosted_release_services (
  release_id     TEXT NOT NULL REFERENCES hosted_releases(release_id),
  service_name   TEXT NOT NULL,
  service_status TEXT NOT NULL DEFAULT 'live',
  PRIMARY KEY (release_id, service_name)
);

CREATE TABLE IF NOT EXISTS hosted_release_logs (
  id         SERIAL PRIMARY KEY,
  release_id TEXT NOT NULL REFERENCES hosted_releases(release_id),
  line       TEXT NOT NULL
);
