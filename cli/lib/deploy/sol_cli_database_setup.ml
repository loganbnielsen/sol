(** The in-cluster database setup step — ADR 0007.

    It runs once per target, after the deploy prerequisites and before the migration
    Job: with the database's administrative credential, it creates the DDL and DML roles
    with Sol-generated passwords and writes their credentials to the target's Secrets.

    The step is part of the *provisioning path*, not a consumer: it receives the master
    for the duration of one Job and never appears in the class model as a role. *)

(** Where the image digest is configured. Mirrors the runner's mechanism
    ([SOL_MIGRATION_RUNNER_IMAGE]): a digest reference is required and a tag is refused.
    The *instruction* differs, because this image is public — see {!setup_image}. *)
let image_env = "SOL_SETUP_POSTGRES_IMAGE"

let not_a_digest_ref ref_ =
  Printf.sprintf
    "%s %S is not a digest reference (<image>@sha256:<64 hex>); this Job runs with the \
     database's administrative credential, so an image reference that can move is not \
     acceptable"
    image_env
    ref_
;;

(** The setup image.

    Unlike the migration runner, this image is **public**: there is nothing to publish,
    only a digest to pin. The error names that resolution rather than telling the
    operator to publish something that does not belong to Sol. *)
let setup_image () =
  match Sol_cli_string.env image_env with
  | Some ref_ when Sol_cli_platform_assets.is_digest_ref ref_ -> Ok ref_
  | Some ref_ -> Error (not_a_digest_ref ref_)
  | None ->
    Error
      (Printf.sprintf
         "no database setup image is configured. Set %s to an image pinned by digest, \
          for example postgres@sha256:<64 hex> - `docker manifest inspect postgres:16` \
          reports the current digest. Unlike the migration runner, this image is public: \
          there is nothing to publish, only a digest to pin"
         image_env)
;;

(** The roles. Fixed names, because the consumer's role determines its credential class
    rather than a user declaration (ADR 0007): the migration Job is DDL, workloads are
    DML, and neither can ask for a higher class. *)
let ddl_role = "sol_migrator"

let dml_role = "sol_app"

(** Idempotent by construction: re-running against a target whose roles exist is a no-op
    in value — the passwords come from the existing Secret (the renderer reads it), so
    the [ALTER] re-applies the same value rather than churning it.

    **The grants belong here, not in the migrations.** A role without them cannot do
    anything. The migration runs as [sol_migrator] and creates the schema's objects, so
    [ALTER DEFAULT PRIVILEGES] for that role is what makes everything it later creates
    reachable by [sol_app], without every migration carrying grants of its own. On
    PostgreSQL 15 and later [public] grants no [CREATE] to [PUBLIC], so [sol_migrator]
    needs it explicitly or the migration cannot create anything.

    Passwords arrive as [psql] variables ([:'ddl_password']) rather than being embedded,
    so this text never carries a secret and the manifest stays free of credential
    material. *)
let role_sql =
  Printf.sprintf
    {sql|DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN
    CREATE ROLE %s LOGIN PASSWORD :'ddl_password';
  ELSE
    ALTER ROLE %s LOGIN PASSWORD :'ddl_password';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN
    CREATE ROLE %s LOGIN PASSWORD :'dml_password';
  ELSE
    ALTER ROLE %s LOGIN PASSWORD :'dml_password';
  END IF;
END
$$;
GRANT USAGE ON SCHEMA public TO %s, %s;
GRANT CREATE ON SCHEMA public TO %s;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %s;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO %s;|sql}
    ddl_role
    ddl_role
    ddl_role
    dml_role
    dml_role
    dml_role
    ddl_role
    dml_role
    ddl_role
    ddl_role
    dml_role
    ddl_role
    dml_role
;;

(** How long the controller waits before collecting a finished Job — and, by cascade,
    the transient master Secret it owns. This is the *backstop*: Sol deletes the Job
    after completion or failure itself, and the TTL covers the case where Sol's process
    dies between applying and deleting. Long enough to read the Job's logs for evidence
    before it disappears. *)
let crash_backstop_seconds = 3600
