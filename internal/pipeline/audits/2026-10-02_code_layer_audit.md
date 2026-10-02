# Code-layer audit — 2026-10-02

Audited `origin/main` `54f53c8e` in an isolated worktree. Six actionable findings:
none high-severity by themselves, four medium and two low, all of the
consolidation kind. The boundaries between the four `cli/lib` domains
(`base ← kube ← workspace ← cloud ← deploy`) and the `framework/ocaml`
packages are sound — dune enforces the direction, and no provider concept
leaks outside `cli/lib/cloud`. What this pass found is the opposite problem:
the same neutral concept materialised two-to-eight times, in a layer that
already owns a home for it.

| Severity | Ticket | Finding | Source |
|---|---|---|---|
| medium | CODE_LAYER-026 | `Sol_cli_fs` is the filesystem boundary but exposes no read; five modules re-implement `read_file` and two re-implement `write_atomic` | `cli/lib/base/sol_cli_fs.ml`; `cli/lib/{workspace/sol_cli_sol_yml,base/sol_cli_json,base/sol_cli_migration_disposition,base/sol_cli_scaffold_tree,cloud/sol_cli_supervised}.ml` |
| medium | CODE_LAYER-027 | `Sol_cli_substrate` derives the same namespace/document set three times; the tested `docs_for_namespaces` is not the path `ensure` uses | `cli/lib/deploy/sol_cli_substrate.ml:12,107-111,179-200` |
| medium | CODE_LAYER-028 | Provider-independent absence helpers are duplicated in the AWS and GCP adapters, with a silently drifted not-found phrase set | `cli/lib/cloud/sol_cli_aws_absence.ml:32-43,420-429`; `cli/lib/cloud/sol_cli_gcp_absence.ml:21-32,363-372` |
| medium | CODE_LAYER-029 | The public-delegation wait is implemented twice, with two ways to read the same domain | `cli/bin/cmd_deploy.ml:140-167`; `cli/bin/cmd_cloud_tf.ml:589-616` |
| low | CODE_LAYER-030 | `sol_process` keeps a legacy `open_process_in`/`Sys.command` shell family that discards exit status and stderr, and `soldev` reads git state through it | `internal/tooling/sol_process/lib/sol_process.ml:158-182`; `internal/tooling/soldev/lib/soldev_merge.ml:7-19,595,908,952-955` |
| low | CODE_LAYER-031 | The DEC-031 target axis is re-declared eight times in `cli/bin`, and the grammar has already drifted | `cli/bin/{cmd_plan,cmd_cloud_tf,cmd_deploy,cmd_migrate,cmd_alert,cmd_target,cmd_logs,cmd_destination}.ml` |

One incidental defect found in passing: `cli/bin/cmd_deploy.ml:355` prints
``run `sol depl       oy %s` again`` (the word `deploy` split by alignment
whitespace) in the environment-refusal guidance. It is folded into
CODE_LAYER-029, which already edits `cmd_deploy.ml`.

## Evidence

Each claim below names the command that was run and, where the claim is an
absence, a positive control that shows the search works.

### CODE_LAYER-026: the filesystem boundary has no read side

`Sol_cli_fs` is the base layer's filesystem boundary; it exports
`mkdir_p`, `write_atomic`, `with_temp_file`, `remove_*`, and `copy_tree` — and
no read at all.

```sh
rg -n '^let read_file' cli/lib
```

```
cli/lib/workspace/sol_cli_sol_yml.ml:161:let read_file path =
cli/lib/base/sol_cli_json.ml:10:let read_file ~what path =
cli/lib/base/sol_cli_migration_disposition.ml:46:let read_file ~path =
cli/lib/base/sol_cli_scaffold_tree.ml:10:let read_file path =
cli/lib/cloud/sol_cli_supervised.ml:119:let read_file path =
```

Positive control that the interface search is real:

```sh
rg -n 'read_file' cli/lib/base/sol_cli_fs.mli   # no output: no read surface
rg -n 'write_atomic|with_temp_file' cli/lib/base/sol_cli_fs.mli
```

```
5:val write_atomic : ?perm:int -> string -> string -> (unit, string) result
7:val with_temp_file
```

The five readers have five contracts for the same operation — `Error msg` with a
raw message (`sol_cli_sol_yml`), a `what`-prefixed message plus JSON decode
(`sol_cli_json`), a hand-rolled `open_in_bin`/`really_input_string` plus
`could not read <path>: <msg>` (`sol_cli_migration_disposition`), the same
message without the manual read (`sol_cli_scaffold_tree`), and
`Some s`/`None` (`sol_cli_supervised`). Two of them use
`In_channel.with_open_text` (newline translation) where the others use
`with_open_bin`. Separately, `write_atomic` is defined three times
(`sol_cli_fs.ml:85`, `sol_cli_sol_yml.ml:166`, `sol_cli_supervised.ml:125`),
and a further 16 `In_channel.with_open_{bin,text} … input_all` reads in
`cli/lib` bypass the boundary entirely and raise `Sys_error`:

```sh
rg -n 'In_channel.with_open_(bin|text)' cli/lib | rg -v 'sol_cli_fs.ml' | wc -l
```

```
16
```

### CODE_LAYER-027: one document set derived three times

```sh
rg -n 'docs_for_namespaces' --glob '!*.md'
```

```
cli/lib/deploy/sol_cli_substrate.ml:12:let docs_for_namespaces namespaces : Sol_cli_yaml.document list =
cli/lib/deploy/sol_cli_substrate.mli:2:val docs_for_namespaces : string list -> Sol_cli_yaml.document list
cli/test/inline/test_substrate.ml:7:  S.docs_for_namespaces namespaces |> List.map (fun doc -> Sol_cli_yaml.render [ doc ])
```

`docs_for_namespaces` has exactly one caller: a test. The production path,
`ensure` (`sol_cli_substrate.ml:107-111`), rebuilds the same list inline, and
`reconcile_operator_bindings` (`sol_cli_substrate.ml:196-200`) recomputes the
namespace set that `operator_binding_docs` (`sol_cli_substrate.ml:179-193`)
already computes. So the function the test asserts on is a *model* of the
production document set, and the two can diverge silently. Positive control
that the seam is real: `Sol_cli_substrate.namespaces` is used on the
production path (`cli/lib/deploy/sol_cli_deploy_run.ml:114,163`).

### CODE_LAYER-028: duplicated absence helpers, already drifted

`lines` is byte-identical in the two adapters, and `unresolved` is
byte-identical:

```sh
rg -n '^let lines |^let unresolved ' cli/lib/cloud/sol_cli_aws_absence.ml cli/lib/cloud/sol_cli_gcp_absence.ml
```

```
cli/lib/cloud/sol_cli_aws_absence.ml:32:let lines output =
cli/lib/cloud/sol_cli_aws_absence.ml:423:let unresolved ~reason =
cli/lib/cloud/sol_cli_gcp_absence.ml:27:let lines output =
cli/lib/cloud/sol_cli_gcp_absence.ml:366:let unresolved ~reason =
```

The not-found phrase sets have drifted — GCP accepts one phrase AWS does not:

| file | phrase list |
|---|---|
| `sol_cli_aws_absence.ml:39-43` | `notfound`, `not found`, `does not exist`, `no such` |
| `sol_cli_gcp_absence.ml:21-25` | `not found`, `notfound`, `does not exist`, `was not found` |

That matters because `not_found` decides whether a provider answer becomes
`Absent` (a claim the resource is gone, which a destroy verification relies on)
or `Unobservable` (fail-closed). Two adapters disagreeing about the wording is
a correctness difference hidden in duplicated code. The `Terraform state
bucket` `External` observation inside `durable_observations` is also
word-for-word shared (only its `identity` string differs).

### CODE_LAYER-029: one bounded wait, written twice

`cmd_deploy.ml:140-167` and `cmd_cloud_tf.ml:589-616` print the identical
banner (same format string), compute `attempts = max 1 (seconds / 5)`, call
`Sol_cli_installation_stage.await_delegation ~run ~report ~attempts
~interval:5. ~domain ()`, and map `Established`/`Unmet`/`Unknown` the same way.
The only difference is an extra `Established` line in bootstrap, and the two
read the domain by different routes — `Sol_cli_installation.zone_domain` in
`cmd_deploy` versus matching `Service_zone { domain; _ }` in `cmd_cloud_tf` —
which is how the same concept grows a second definition.

### CODE_LAYER-030: the legacy shell family reads failure as empty

```sh
rg -n '^let (lines_shell|output_shell|run_shell_rc|run_shell_ok)' internal/tooling/sol_process/lib/sol_process.ml
```

```
158:let lines_shell ?(echo = false) cmd =
166:let output_shell ?(echo = false) cmd =
174:let run_shell_rc ?(echo = true) cmd =
179:let run_shell_ok ?(echo = true) cmd =
```

`lines_shell`/`output_shell` use `Unix.open_process_in (cmd ^ " 2>/dev/null")`
and `run_shell_rc` uses `Sys.command`: exit status and stderr are discarded.
The correct argv runner exists beside them and returns
`{status; stdout; stderr}` (`run_argv`) — the positive control.
`soldev_merge.ml` reads its git state through the discarded family:
`current_branch` via `output_shell` (`soldev_merge.ml:12`),
`shell_output_trim` for `git status --porcelain` (`soldev_merge.ml:908`,
used at `917-948`), `git_branch_exists` via `run_shell_rc` (`soldev_merge.ml:16`),
and `worktree_snapshots` via `Soldev_shell.run_cmd_lines` → `lines_shell`
(`soldev_merge.ml:952-955`). A failed `git worktree list` therefore becomes
`[]`, and a failed `git status` becomes `""` → `dirty = false`. This is the
same error/empty conflation that CODE_LAYER-024 fixed for `open_prs`, in the
same file. It overlaps `REFAC-113` (whether the process layer should sit on
`bos`), but is independent of that decision: the legacy family should not
exist either way.

### CODE_LAYER-031: the primary axis is re-declared per command

```sh
rg -n '^let target_arg' cli/bin/*.ml
```

```
cli/bin/cmd_migrate.ml:319:let target_arg =
cli/bin/cmd_alert.ml:45:let target_arg =
cli/bin/cmd_plan.ml:91:let target_arg =
cli/bin/cmd_deploy.ml:743:let target_arg =
cli/bin/cmd_cloud_tf.ml:330:let target_arg =
cli/bin/cmd_target.ml:178:let target_arg =
cli/bin/cmd_destination.ml:5:let target_arg =
cli/bin/cmd_logs.ml:410:let target_arg =
```

`cmd_plan.ml:91` and `cmd_cloud_tf.ml:330` are byte-identical (required
positional, `~docv:"TARGET"`). `cmd_deploy.ml:743` is the required positional
with a longer doc; `cmd_migrate.ml:319` is an *optional* positional
(`value & pos 0 … None`) with a third doc. The view/scope-primary commands
(`cmd_alert`, `cmd_target`, `cmd_logs`, `cmd_destination`) use the `--target`
flag form with `~docv:"ENV/PROVIDER/REGION"`. DEC-031's split — target-primary
takes the positional, every other axis a flag — is stated in `AGENTS.md` but
not declared once in code, so the flag/positional distinction and the
`<env>/<provider>/<region>` grammar are re-typed at each site and have already
diverged in `docv` and verbosity.

## Retained candidates and existing work

- **Not filed: splitting `cli/lib/workspace/sol_cli_config.ml` (1445 lines).**
  It holds the workspace model, the `environments.yml` decoder, target
  resolution/validation, and `local_infra` — four reasons to change. It is
  real, but `REFAC-140` already owns the mechanical split of every
  banner-divided file, and this one would be better decided together with it
  than filed as a separate low-confidence split.
- **Not filed: `Sol_cli_manifest.apply` / `sol_cli_manifest_yaml.ml` (856
  lines of Kubernetes YAML) living in the `workspace` library.** Rendering and
  applying manifests is kube-layer work in a workspace-layer file, but
  `workspace` already depends on `kube`, the rendering has no transport
  dependency, and moving it would touch the deploy path broadly for a naming
  win. Recorded here as a residual risk, not a finding.
- Provider dispatch (`sol_cli_provider_registry.ml`), the neutral
  `Sol_cli_absence` observation model, the explicit `deps` records in
  `sol_cli_cloud_{apply,destroy,wiring}.ml`, and the `Planning_input` record
  are deliberate boundaries, not findings. Long argument lists or closure
  records alone establish no defect.
- `REFAC-113` (process layer on `bos`) and `REFAC-140` (banner-file splits)
  are the adjacent open work; `CODE_LAYER-030` cross-references
  `REFAC-113` rather than duplicating it.
- Active workstreams were read first and left alone: secrets/identity
  (`DEC-029`, `DEC-061`, `DEC-062`, `DEC-063`, `BUG-054`) and
  verification/tests (`VERIF-*`, `REFAC-161`). No finding touches
  `sol_cli_secret.ml`, `sol_cli_sensitive_vars.ml`, `sol_cli_redaction.ml`,
  the authorization root, or a test suite's membership.
- Cross-language parity (DEC-022): every finding is CLI/platform-internal
  tooling or provider adapters. None changes a schema-registry convention,
  wire format, trace propagation, retry/DLQ contract, lifecycle, or
  app-author surface, so there is no TypeScript-parity impact.

## Recommended path

`command -> one shared arg grammar / one bounded wait -> one adapter per
provider -> one shared filesystem or neutral-model helper`

Keep protocol and subprocess details in their existing adapters; consolidate
the neutral concepts that two or more adapters already share into the module
that already owns them (`Sol_cli_fs`, `Sol_cli_absence`,
`Sol_cli_installation_stage`, `Sol_cli_substrate`). No new layer or package is
recommended.

## Reproduce the findings

```sh
# 026
rg -n '^let read_file' cli/lib
rg -n 'val read_file' cli/lib/base/sol_cli_fs.mli && echo 'unexpected: read surface exists'
rg -n '^let write_atomic' cli/lib
rg -n 'In_channel.with_open_(bin|text)' cli/lib | rg -v 'sol_cli_fs.ml' | wc -l

# 027
rg -n 'docs_for_namespaces' --glob '!*.md'

# 028
rg -n '^let lines |^let unresolved ' cli/lib/cloud/sol_cli_aws_absence.ml cli/lib/cloud/sol_cli_gcp_absence.ml
sed -n '39,43p' cli/lib/cloud/sol_cli_aws_absence.ml
sed -n '21,25p' cli/lib/cloud/sol_cli_gcp_absence.ml

# 029
sed -n '140,167p' cli/bin/cmd_deploy.ml
sed -n '589,616p' cli/bin/cmd_cloud_tf.ml
sed -n '355p' cli/bin/cmd_deploy.ml

# 030
rg -n '^let (lines_shell|output_shell|run_shell_rc|run_shell_ok)' internal/tooling/sol_process/lib/sol_process.ml
rg -n 'output_shell|lines_shell|run_shell_rc|shell_output_trim' internal/tooling/soldev/lib/soldev_merge.ml

# 031
rg -n '^let target_arg' cli/bin/*.ml
```

## Executed checks

- `git rev-parse --short HEAD` → `54f53c8e`; canonical checkout clean.
- Every command in § *Reproduce the findings* was run on this commit; the
  outputs above are verbatim.
- Provider leakage check with a positive control:
  `rg -n 'Sol_cli_provider\.(Aws|Gcp)|"aws"|"gcp"' cli/lib/{deploy,workspace,local,base}`
  returns only `sol_cli_config.ml:65` (a default value) and
  `sol_cli_provider.ml` (the provider's own module) — i.e. the cloud boundary
  is clean.
- Dead-name scan over `cli/lib` (exported names with no reference outside
  their own file) was run and produced only internal helpers re-used within
  their module, so no dead-module finding was filed from it.

## Filing validation

`soldev pipeline validate` reads all tickets after this filing. `git diff --check`
passes. No source files are changed by this audit commit.
