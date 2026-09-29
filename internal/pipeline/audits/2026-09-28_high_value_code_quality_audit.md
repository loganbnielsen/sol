# High-value code quality audit — 2026-09-28

Third pass, pinned to origin/main `6eb36b2c`. Six new high-severity findings selected for outage, schema/recovery safety, authorization, retry isolation and credential delivery impact. No runtime fixes or live infrastructure mutations. This is a targeted audit, not an exhaustive absence-of-defects claim.

| Ticket | Finding |
|---|---|
| BUG-077 | Make scoped deployment release records safe for workspace rollback |
| BUG-078 | Check target applied migrations before restoring an old release |
| BUG-079 | Enforce not-before claims for verified JWT authentication |
| BUG-080 | Keep retry and DLQ topics isolated by the original consumer group |
| BUG-081 | Preserve External Secrets selection in emitted GitOps artifacts |
| BUG-082 | Fail closed when the migration directory cannot be inspected |

## BUG-077: Make scoped deployment release records safe for workspace rollback

Source: `cli/lib/deploy/sol_cli_deploy_selection.ml:158; cli/lib/deploy/sol_cli_deployment_plan.ml:893-941; cli/lib/deploy/sol_cli_release.ml:76; cli/lib/deploy/sol_cli_release_store.ml:record; cli/lib/deploy/sol_cli_rollback.ml:441-447,480,589-626`.

A scoped deployment stores only selected plan.services and advances the workspace-wide release pointer. Rollback treats those partial workloads as the entire workspace boundary and prunes every other live workload. Updating A can make rollback to that record delete untouched B. This is a documented valid scope causing an outage, not merely a malformed record.

Smallest remediation: Keep recorded workspace release boundaries complete after a scoped deploy, preserving unaffected workload facts from a validated current boundary. Reject unavailable/inconsistent prior evidence before unsafe mutation. An explicitly typed scope-owned release model is an alternative only if rollback and pointer semantics change coherently; do not leave a partial snapshot masquerading as a full boundary.

## BUG-078: Check target applied migrations before restoring an old release

Source: `cli/bin/cmd_rollback.ml:39-44; cli/lib/deploy/sol_cli_rollback.ml:262-287; cli/lib/deploy/sol_cli_migration_gate.ml:read_applied`.

Rollback computes migrations beyond the historical release from files discovered in the local checkout. After a contracting migration has been applied to the target, running rollback from the old checkout omits that file and passes the guard. Incompatible old application code is then restored against the changed database.

Smallest remediation: Derive compatibility from the target's applied migration state and durable disposition evidence for applied changes beyond the historical release. Fail closed when evidence or target reads are unavailable. An absent local file is not evidence that the target schema did not change. Reuse existing migration status infrastructure where appropriate.

## BUG-079: Enforce not-before claims for verified JWT authentication

Source: `framework/ocaml/sol-svc/lib/auth_internal.ml:213,295-315`.

An authentically signed HS256 token with valid issuer/audience/expiration and nbf one hour in the future authenticates immediately. The selected Jose verifier checks expiration but does not enforce nbf. This permits access before the issuer's declared validity window. Fractional expiration additionally raises Type_error and becomes HTTP 500; it does not bypass expiration.

Smallest remediation: Validate supported temporal claims at the verified authentication boundary, enforcing present nbf and expiration semantics with finite NumericDate handling. Preserve signature verification, issuer/audience checks, and existing optional-claim policy. Convert malformed claims into typed authorization failures rather than exception-driven 500 responses. Record any intentional clock-skew policy explicitly.

## BUG-080: Keep retry and DLQ topics isolated by the original consumer group

Source: `framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml:180-202,432-440`.

Short group IDs pay.ments, pay_ments and pay-ments all produce orders.pay-ments.retry and the same DLQ. Relay consumers retain distinct original group IDs plus -sol-retry, so each independent group consumes the others' retry records. This mixes business handlers and creates duplicate or wrong-group effects. The source identity can be ordinary framework-generated dotted consumer groups.

Smallest remediation: Derive bounded relay topic names from a collision-resistant representation of the original group ID, including short IDs whose punctuation is normalized. Apply the same rule to retry and DLQ. Update affected callers/fixtures together; do not add compatibility aliases for the unreleased API.

## BUG-081: Preserve External Secrets selection in emitted GitOps artifacts

Source: `cli/bin/cmd_deploy.ml:176,298,499; cli/lib/deploy/sol_cli_factory.ml:29; cli/lib/deploy/sol_cli_executor.ml:81`.

The CLI accepts External_secrets and dry-run renders the chosen ExternalSecret/store. Actual Emit_to execution unconditionally replaces the selected backend with Kubernetes_placeholder, emitting an ordinary blank Secret. Applying the artifact prevents ESO from supplying credentials and can overwrite existing values with blanks. Preview and actual output disagree while both exit successfully.

Smallest remediation: Preserve safe External_secrets and Kubernetes_placeholder backend choices through emission. Reject Kubernetes_live at the shared artifact boundary rather than overriding every backend. Keep CLI and library callers on the same safety contract.

## BUG-082: Fail closed when the migration directory cannot be inspected

Source: `cli/lib/base/sol_cli_migration.ml:54-82; cli/lib/deploy/sol_cli_migration_gate.ml:verify; cli/lib/workspace/sol_cli_workspace_scan.ml:fold_dir,discover_migrations`.

Sol_cli_migration.required catches every Sys_error from readdir and returns Ok []. An existing unreadable directory or regular file at the migrations path therefore becomes No_migrations in the production deployment gate. Workspace discovery also warns and substitutes an empty list. The schema prerequisite can be skipped because inspection failed.

Smallest remediation: Distinguish a genuinely absent optional migrations directory from permission, wrong-kind and other inspection failures. Propagate those failures through migration prerequisite verification and safety-sensitive discovery; retain the documented empty result for absence and truly empty directories.

## Evidence and limits

- Scoped rollback: the unchanged surplus predicate selects no deletion for expected A+B and selects notify-worker for expected A alone. Source tracing follows selected plan -> partial release -> global pointer -> complete live workspace scan -> kubectl delete. No live workload was deleted.
- Migration rollback: the unchanged production guard and disposition reader reject a declared contract file in the current checkout, but allow the old checkout list after removing that file, despite the scenario's unchanged migrated target. This reproduces the input-dependent guard bypass; no actual database was migrated.
- JWT: copied unchanged Auth/Auth_internal modules with installed Jose and supporting packages authenticate a signed future-nbf token. Valid/expired integer-exp controls authenticate/reject respectively. Fractional expired exp raises Type_error, not authentication. The author recompiled/repeated the probe; no network request is involved. The original link command needed the installed digestif.ocaml backend; the corrected runnable command below includes it.
- Retry topics: unchanged naming helpers map three different short IDs to one topic; payments/analytics controls remain distinct. The routing consequence is source-traced through distinct relay consumer groups. No broker was started and no cross-group live message was delivered.
- GitOps: the real CLI on a temporary minimal workspace exits 0 for both modes. Dry-run renders ExternalSecret/probe-store; actual output contains Secret and neither ExternalSecret nor probe-store. No artifact was applied.
- Migration discovery: unchanged required function on a temporary readable directory returns one migration; after chmod 000 it returns zero, and a regular-file path also returns zero. The author runs as uid 1000, so the permission probe is effective. Source tracing verifies zero maps to No_migrations.

JWT not-before semantics were verified against [RFC 7519 §4.1.5](https://www.rfc-editor.org/rfc/rfc7519.html#section-4.1.5): a present nbf forbids acceptance before its validity time (subject to a deliberate small skew allowance). The test uses a full hour, so ordinary clock-skew allowance would not account for it.

## Scope, retained work and deduplication

Followed release recording and rollback pruning, migration prerequisites/dispositions/status paths, verified auth, retry/DLQ naming and relay consumption, secrets artifact emission, and representative tests/interfaces. Included foundation calls only where they determine these contracts. Previous fourteen findings were excluded.

Pending-ticket searches used `rg -n` across BACKLOG/READY for nbf/not-before/temporal checks, retry/group naming collisions, scoped release/rollback pruning, applied migration/contract rollback, External_secrets/Emit_to, and unreadable migration discovery. Relevant controls/records were read: BUG-071 ownership, BUG-072 scheduled policy loss, FEAT-094 checksums, SEC-011 migration publisher boundary, and existing surplus-pruning/migration/signature/relay tests. No existing duplicate was identified in the inspected results; this is bounded search evidence.

FEAT-094 already owns migration checksums. Pg_db cancellation remains unfiled because current external source could not be established as Sol's pinned source and pool rollback behavior was unresolved. No naming/style cleanup or speculative abstraction ticket was filed. Production Terraform/provider qualification, all external packages and every file were not exhaustively audited.

Recommended shape stays `validated target -> complete release/operation boundary -> checked adapter -> typed outcome`. Repair safety invariants in shared boundaries; no additional architecture framework is needed.

## Validation

CLI and soldev build passed. Reproductions use the e2e skill's focused debugging workflow. This filing changes only reports, tickets and the work summary, so full integration/cloud qualification is outside its validation. All six documented probes were repeated successfully. Ticket validation reads 836 tickets across three states with all frontmatter readable. Whitespace and ownership checks pass before submission.

## Runnable reproductions

Run from the audited checkout with its opam switch active and CLI built. Extracted functions are unchanged; lightweight type stubs isolate predicates without claiming a live deployment test. Temporary files are removed. The permission probe requires an unprivileged user.

### BUG-077

```sh
{
cat <<'EOF'
module Sol_cli_deployment_plan=struct type service_spec=string end;;
type workload_identity=string;;
let identity_of_spec x=x;;
let same_identity=String.equal;;
EOF
sed -n '441,447p' cli/lib/deploy/sol_cli_rollback.ml
cat <<'EOF'
let show label expected =
 let deleted=unexpected_workloads ~expected ~live:["charge-svc","a";"notify-worker","b"] in
 Printf.printf "%s: prune=[%s]\n" label (String.concat "," (List.map fst deleted));;
show "complete boundary control" ["charge-svc";"notify-worker"];;
show "scoped boundary" ["charge-svc"];;
EOF
} | opam exec -- ocaml -noinit -noprompt
```

### BUG-078

```sh
{
cat <<'EOF'
module Sol_cli_string = struct let is_blank s = String.trim s = "" end;;
#mod_use "cli/lib/base/sol_cli_migration_disposition.ml";;
module Sol_cli_release = struct type t = {release_id:string; migrations:string list} end;;
type migration_check_error =
 Contracting_migration of {release_id:string;migration:string}
 | Undeclared_disposition of {release_id:string;migration:string;reason:string};;
EOF
sed -n '262,287p' cli/lib/deploy/sol_cli_rollback.ml
cat <<'EOF'
let release = {Sol_cli_release.release_id="old"; migrations=["0001_init.sql"]};;
let dir = Filename.concat (Filename.get_temp_dir_name ()) ("sol-rollback-audit-" ^ string_of_int (Unix.getpid ()));;
Unix.mkdir dir 0o700;;
let contract = Filename.concat dir "0002_contract.sql";;
Out_channel.with_open_text contract (fun ch -> output_string ch "-- sol:disposition contract\nALTER TABLE orders DROP COLUMN legacy;\n");;
let show label files =
 let result = check_migration_boundary ~release ~migrations_dir:dir ~current_migrations:files in
 Printf.printf "%s: %s\n" label (match result with Ok () -> "Allowed" | Error (Contracting_migration _) -> "Refused contract" | Error _ -> "Refused missing disposition");;
show "current checkout control" ["0001_init.sql";"0002_contract.sql"];;
Sys.remove contract;;
show "old checkout, same migrated target" ["0001_init.sql"];;
Unix.rmdir dir;;
EOF
} | opam exec -- ocaml -noinit -noprompt -I +unix unix.cma
```

### BUG-079

```sh
audit_tmp=$(mktemp -d)
cp framework/ocaml/sol-svc/lib/auth.ml framework/ocaml/sol-svc/lib/auth_internal.ml "$audit_tmp/"
cat > "$audit_tmp/probe.ml" <<'EOF'
let secret = "test-hs256-shared-secret"
let config = `Jwt Auth.{ scopes = []; verification = Verified_signature_required { issuer = "issuer"; audience = "audience"; algorithms = [`HS256]; key_source = Hs256_secret secret } }
let check name extra =
  let payload = `Assoc (["iss", `String "issuer"; "aud", `String "audience"; "sub", `String "user"] @ extra) in
  let jwt = Result.get_ok (Jose.Jwt.sign ~payload (Jose.Jwk.make_oct secret)) in
  let headers = Http.Header.of_list ["authorization", "Bearer " ^ Jose.Jwt.to_string jwt] in
  let outcome = try match Auth_internal.validate config headers with
  | Ok _ -> "AUTHENTICATED"
  | Error (`Unauthorized s) -> "rejected: " ^ s
  | Error _ -> "other error"
  with exn -> "RAISED: " ^ Printexc.to_string exn
  in
  Printf.printf "%s -> %s\n" name outcome
let () =
  let now = Unix.gettimeofday () in
  check "expired integer exp positive control" ["exp", `Int (int_of_float (now -. 3600.))];
  check "expired fractional exp" ["exp", `Float (now -. 3600.)];
  check "future nbf with valid integer exp" ["exp", `Int (int_of_float (now +. 7200.)); "nbf", `Int (int_of_float (now +. 3600.))];
  check "valid integer exp positive control" ["exp", `Int (int_of_float (now +. 3600.))]
EOF
opam exec -- ocamlfind ocamlopt -linkpkg -package digestif.ocaml,jose,yojson,base64,ptime,cohttp,eio,https-eio -I "$audit_tmp" -o "$audit_tmp/probe" "$audit_tmp/auth.ml" "$audit_tmp/auth_internal.ml" "$audit_tmp/probe.ml"
"$audit_tmp/probe"
rm -r "$audit_tmp"
```

### BUG-080

```sh
audit_tmp=$(mktemp -d)
sed -n '178,203p' framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml > "$audit_tmp/probe.ml"
cat >> "$audit_tmp/probe.ml" <<'EOF'
let () = List.iter (fun group_id -> Printf.printf "%S -> %s\n" group_id (relay_topic_name ~source:"orders" ~group_id ~suffix:"retry")) ["payments";"analytics";"pay.ments";"pay_ments";"pay-ments";"";"unscoped"]
EOF
opam exec -- ocamlc -o "$audit_tmp/probe" "$audit_tmp/probe.ml"
"$audit_tmp/probe"
rm -r "$audit_tmp"
```

### BUG-081

```sh
python3 - <<'EOF'
import tempfile, pathlib, subprocess, os
tree = str(pathlib.Path.cwd())
with tempfile.TemporaryDirectory(prefix="sol-eso-probe-") as temporary:
    root = pathlib.Path(temporary)
    (root / "app/api/api_svc").mkdir(parents=True)
    (root / "sol").mkdir()
    (root / "sol.yml").write_text("project: probe\nservices:\n  api_svc:\n    type: http\n    path: app/api/api_svc\n    language: ocaml\n")
    (root / "sol/environments.yml").write_text("dev:\n  targets:\n    aws/us-east-1:\n      registry: registry.example.com/probe\n      kube_context: probe-context\n")
    (root / "app/api/api_svc/sol.toml").write_text("")
    (root / "app/api/api_svc/Dockerfile").write_text("FROM scratch\n")
    env = dict(os.environ, SOL_HOME=tree, XDG_DATA_HOME=str(root / "state"))
    command = [tree + "/_build/default/cli/bin/main.exe", "deploy", "dev/aws/us-east-1", "--image-tag", "test", "--emit-to", str(root / "out"), "--secret-backend", "external-secrets", "--secret-store-ref", "probe-store"]
    for extra in [["--dry-run"], []]:
        result = subprocess.run(command + extra, cwd=root, env=env, text=True, capture_output=True)
        print("mode", extra, "exit", result.returncode)
        assert result.returncode == 0, (result.stdout, result.stderr)
        if extra:
            print("\n".join(line for line in result.stdout.splitlines() if "kind: ExternalSecret" in line or "probe-store" in line))
        else:
            for path in (root / "out").glob("*.yaml"):
                text = path.read_text()
                if "kind: Secret\n" in text or "kind: ExternalSecret" in text:
                    print(path.name, "ExternalSecret=", "kind: ExternalSecret" in text, "store=", "probe-store" in text, "Secret=", "kind: Secret\n" in text)
EOF
```

### BUG-082

```sh
{
sed -n '1,84p' cli/lib/base/sol_cli_migration.ml
cat <<'EOF'
let dir = Filename.temp_file "sol-migration-audit" "";;
Sys.remove dir;;
Unix.mkdir dir 0o700;;
let file = Filename.concat dir "001_init.sql";;
Out_channel.with_open_bin file (fun o -> output_string o "SELECT 1;");;
let show label = function Ok xs -> Printf.printf "%s: Ok migrations=%d\n%!" label (List.length xs) | Error e -> Printf.printf "%s: Error %s\n%!" label e;;
show "readable control" (required ~dir);;
Unix.chmod dir 0o000;;
show "unreadable existing directory" (required ~dir);;
Unix.chmod dir 0o700;;
show "regular file instead of directory" (required ~dir:file);;
Sys.remove file;;
Unix.rmdir dir;;
EOF
} | opam exec -- ocaml -noinit -noprompt -I +unix unix.cma
```

## Deduplication command and positive controls

```sh
rg -n 'nbf|not.before|pay.ments|scoped.*rollback|applied.*migration|External_secrets|Emit_to|unreadable.*migration' internal/pipeline/tickets/BACKLOG internal/pipeline/tickets/READY_FOR_ENGINEERING
```

The repeated search matches the newly filed BUG-077..082 (positive controls) and existing FEAT-094 checksum work. Those matches were inspected; checksum work is a separate premise. The search does not establish that every differently worded ticket has been excluded.
