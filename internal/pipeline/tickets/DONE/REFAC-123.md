---
id: REFAC-123
type: refactor
severity: medium
title: Decode blank to None at the boundary -- an optional string inside Sol is never Some ""
source: operator review (2026-09-26), on the REFAC-121 is_blank helper
---

**Depends on:** None.

## The problem

REFAC-121 gave Sol one spelling of "is this blank?" (`Sol_cli_string.is_blank`, `non_blank`, `non_blank_opt`, `non_empty`). The operator's point is that the question shouldn't be asked at the use sites at all. If `Some ""` and `Some "  "` can reach a consumer, every consumer has to remember that they mean `None`. The helper makes the check shorter; it doesn't make it unnecessary.

`git grep -c 'Sol_cli_string\.\(is_blank\|non_blank_opt\|non_blank\|non_empty\)\b' origin/main -- cli` (2026-09-26) finds 28 use sites across 18 files. They cluster in the consumers of decoded config and process output: `sol_cli_profile_preflight.ml` (3), `sol_cli_aws_destruction.ml` (3), `sol_cli_cluster.ml`, `sol_cli_open.ml`, `sol_cli_provider_capabilities.ml` and `cmd_migrate.ml` (2 each). There are also about 73 hand-written `= ""` comparisons in `cli/**/*.ml`, and some of them are the same check.

## Remediation

Normalise once, where a string enters Sol, so that inside Sol `string option` means "absent or a real value":

- **Config decoder** (`Sol_cli_config`, `Sol_cli_manifest_yaml`, `Sol_cli_toml`):
  - A blank optional scalar decodes to `None`. Unquoted `""`/`~`/`null` already does; quoted `""` and whitespace-only values should too.
  - A blank *required* field is a decode error that names the path, not a `""` passed downstream.
- **Environment**: `Sol_cli_string.env` is the boundary; raw `Sys.getenv_opt` calls for settings go through it.
- **Process output**: adapters that read a value from a command (`kubectl … -o jsonpath`, `aws … --output text`, `terraform output`) return `None` or an `Error` for empty or whitespace output. Consumers must not trim or test the output again.
- **CLI arguments**: Cmdliner converters for names, targets and similar values reject an empty value at parse time (exit 124).
- **A private `Non_empty.t`** only where a value crosses several modules and the type is doing real work, for example identities that end up in names or ARNs. Don't use it everywhere.
- **Empty is not a sentinel, for strings or collections** (operator, 2026-09-26, on `sol_cli_port_forward.ml` and `sol_cli_rollout_diagnosis.ml`: "I don't like having empty string representable in the codebase"; "Non Empty List?"). A function that has nothing to return returns `None` (or an `Error` when something went wrong), not `""` or `[]`. For example, `read_last_lines`, `pid_owning_port`'s `digits = ""` and `stop_all`'s `[||]`. Where "at least one" is part of the meaning, use a non-empty type (`'a * 'a list`, or a small `Non_empty` module next to `Non_empty` strings). Otherwise a plain list that may be empty is fine: the rule is about sentinels, not about banning empty lists.
- Then remove the use-site checks the boundaries now guarantee. `Sol_cli_string` keeps `env`, `contains`, and whatever the boundaries themselves use. Delete helpers that no longer have callers.

## Acceptance criteria

- Every remaining `Sol_cli_string.is_blank`/`non_blank*`/`non_empty` call is at a decode or adapter boundary. The completion notes list them with `git grep` output.
- Tests at each boundary:
  - a quoted blank optional config value decodes to `None`;
  - a blank required value is a decode error naming its path;
  - an empty process output is `None` or `Error`;
  - an empty CLI argument is refused.
- Consumers pattern-match on `None | Some v` with no re-trimming.
- Demo/example: not applicable (internal; no author-facing change except blank values being refused earlier). State it in the notes.
- Language parity: no impact (CLI-internal).

## Completion notes

**Premise verified (2026-09-26):** 28 use-site `is_blank`/`non_blank*`/`non_empty` checks in `cli` (tests excluded), and a quoted `registry: ""` decoded to `Some ""`.

What changed, by boundary:

- **Config decoder.** `scalar_text` is the one place blank is decided. After trimming, blank is `None`, quoted or not, and a present value is stored trimmed. Every target key already refuses a missing value with its name, so `registry: ""` now fails as "missing value for registry", the same as an unquoted empty value always did. The consumers' re-checks are gone: `state_bucket`, the provider fields (lock table, identities), the preflight's `cluster_endpoint_cidr`, the alert fields (their "is empty" branches merged into "is missing"), and `base_domain`.
- **CLI arguments.** `Sol_cli_args.text` is Cmdliner's `string` with blank refused at parse time (exit 124) and the value trimmed. It applies to 50 name/target/path/URL/tag arguments. `sol secret set --value` keeps `string`, because a secret's value is data. `resolve_commit`'s own blank check is gone. The real-binary rule checks that `--commit ""` and `--base-domain "  "` are refused by the parser.
- **Environment.** Settings go through `Sol_cli_string.env`, which now trims and treats blank as unset: 13 reads, plus `SOL_HOME`, whose blank handling moved out of `resolve_from`. `SOL_LOKI_PASSWORD` uses `non_empty`, because a password's whitespace is data. Secret values that are forwarded into Kubernetes Secrets keep raw reads.
- **Process output.**
  - `Sol_cli_process.failure_output`, which could return `""`, is replaced by `failure_message : failure -> string`. It is never empty: stderr, else stdout, else "exited with code N".
  - `Non_zero` now carries a named `failure` record, defined before `output` so an unannotated `.stdout` stays the success record's.
  - The kubectl probe returns `Succeeded | Failed of failure`, not an exit code with a possibly-empty reason.
  - Migration evidence: the waiting detail and the logs are `string option`, and `evidence_report` returns `None` when there is nothing to report. The kubectl parsing in `container_waiting_status` is where blank becomes `None`.
- **Dead code removed.** The AWS destruction had "the target declares no region" branches. The target path parser already refuses an empty region, verified with `sol plan prod/aws/` → "target must look like <env>/<provider>/<region>", so those branches go.
- **Deliberately unchanged.** `Sol_cli_cluster.process_output` still maps a successful run to `Some stdout`, even when stdout is blank. Readiness checks use it to mean "succeeded", and a silent success must stay a success. Its callers that parse the output (the STS principal, the ADC token) are each that tool's decode.

**What remains:** `git grep -n 'Sol_cli_string\.\(is_blank\|non_blank_opt\|non_blank\|non_empty\)\b' -- cli` (tests excluded) gives 17 calls, all at a boundary:

- kubectl/aws/git output adapters: `container_waiting_status`, `status_job_evidence`, `aws_list_probe`, `git_sha`, the STS principal;
- decoders: the migration disposition header, the terraform-output decoder in `sol_cli_cluster`, `Sol_cli_open.parse_scope`, the TOML volume size, the supervisor's metadata file, the lease's `resourceVersion`;
- constructors: `Sol_cli_kube_destination.of_context`, `Sol_cli_terraform.targets`;
- the password read.

A private `Non_empty` type was not needed: no value crosses modules that the boundaries above don't already normalise.

**Tests:**

- quoted blank and quoted empty config values are refused, naming the key, and a padded value is trimmed (the positive control);
- `failure_message` is never empty;
- the evidence report is `None` without observations;
- an empty or blank `SOL_HOME` reads as unset;
- the parser refusals in the real-binary rule.

Two library tests that pinned removed use-site checks moved to the parser rule. 66 CLI suites pass; format is clean; the offline lifecycle harness passes.

**Demo/example:** not applicable. The author-facing change is that blank values are refused earlier, with the key or flag named. **Language parity:** no impact (CLI-internal).
