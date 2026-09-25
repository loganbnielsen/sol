# Independent post-implementation audit — Sol cloud lifecycle simplification

**Audited revision:** `main` @ `0b3441a8ca8e2d68d857297d77dc29055300e0e6` (clean; synchronized
with `origin/main`).
**Program:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`
(stages S1–S11), landed as PRs #491 and #493–#508.
**Nature:** verification only. No code, ticket, decision, Terraform state or cloud resource was
modified by the audit.

## Verdict

```text
PASS WITH FOLLOW-UPS
```

S1–S11 were substantively implemented and their acceptance evidence is on `main`. The duplicated
Terraform ownership model was deleted rather than relocated (REFAC-094: +501 / −4227;
`sol_cli_destroy_verification` 1669 → 206 pure lines). Terraform supervision and durable completion
evidence work, with the failure it removes reproduced and a positive control. Destroy-path safety
invariants survive with executable evidence. Generic lifecycle edits for an Azure-on-paper addition
fell from about 45 to zero. Conceptual complexity decreased materially.

Seven bounded follow-ups were found. None falsifies a premise and none breaks a guarantee; three
are pre-existing, one is a relocation the program introduced, one is a guard-coverage gap.

## Stage matrix

| Stage | Verdict | Principal evidence | Gap |
|---|---|---|---|
| S1 evidence hygiene / db_password / provider-match guard | PASS | `provider_creates_postgres` gone; `Sol_cli_sensitive_vars` derives secrets from the root; AWS precondition at plan time; GCP has no default; ratchet at 1 dispatch / 0 wildcards with a justified entry | AUDIT-POST-003, AUDIT-POST-006 |
| S2 Terraform authority + abandonment guard | PASS | DEC-045 recorded from primary sources; exactly one relinquish attribute, annotated `# residue:`; rule 4 mutation-tested | AUDIT-POST-005 |
| S3 historical record correction | PASS | Dated corrections appended to the Attempt 5/6 records, FND-0030/0055/0056, DEC-044, INV-DESTROY-1/4; history preserved; SIGPIPE described as fix-pending | — |
| S4 supervision + durable completion evidence | PASS | Supervisor in its own session, durable stdout/stderr, atomic `exit` record; one SIGINT to Terraform's pid only; no timeouts/SIGKILL; Running/Resolved/Unresolved; `errored.tfstate` surfaced and preserved | AUDIT-POST-004 |
| S5 deletion of the duplicated ownership model | PASS | B2/`declared_*`/obligations/A1/exit 3/identities gone; EIP/NAT/ECR sweep rows gone; no provider absence query for a Terraform-managed kind | — |
| S6 capabilities + registry | PASS | `capabilities_of` exhaustive and wildcard-free; table-shaped data behind it; selection for cluster/destruction/credentials in the registry | two dispatch modules rather than the plan's one (layering) |
| S7 generic apply sequence | PASS | `Sol_cli_cloud_apply.execute ~deps`, no provider selection; `cloud_init` 575 → 195 lines | AUDIT-POST-002 |
| S8 opaque cluster access | PASS | `Aws_outputs \| Gcp_outputs` replaced by `Sol_cli_cluster.t`; provider output records private; no universal optional-field record | AUDIT-POST-001 |
| S9 retention + residue capabilities | PASS | Sol owns `destroy_retention`; provider answers Supported/Unsupported-equivalent; GCP refusal maps to `Block_destroy`; residue limited to non-Terraform objects | — |
| S10 provider-owned target configuration | PASS | provider-native identity moved into the target's `aws:`/`gcp:` blocks; flat fields removed from `Sol_cli_config.target` | AUDIT-POST-003 |
| S11 Azure-on-paper fitness test | PASS (ticket) / PARTIAL (plan wording) | static re-run: 0 generic lifecycle edits, 4 registry/type arms; `check_destroy_completeness.sh` derives roots | plan said "one registration arm" |

UNVERIFIABLE OFFLINE (belongs to HARDEN-006/007): the Terraform authority premise against real
providers, live retention/residue behaviour, and the measured Azure compile experiment.

## Findings

### AUDIT-POST-001 — AWS identity remains in the generic lifecycle (medium)

`Sol_cli_cloud_lifecycle` exports an AWS-native identity model: `type whoami_identity =
{ arn; canonical_arn; username; source }`, `whoami_identity_of_json`, `index_of_substring`,
`role_name_of_arn`, `principal_role_name`, `principal_matches`
(`sol_cli_cloud_lifecycle.ml:1152-1330`, `.mli:340-370`). The only product consumer is
`Sol_cli_aws_cluster` (plus tests); present at baseline `c91af060` (lines 1386-1530). This
contradicts plan decision 2 ("No ARN … in generic types or modules") and the module's own header
("Provider-specific *identity* is deliberately absent"). No behavioural defect.

### AUDIT-POST-002 — AWS resource type inside the generic apply sequence (medium)

`Sol_cli_cloud_apply.ml:74` hard-codes `resource_type:"aws_ecr_repository"`, and the generic deps
record carries `confirm_ecr_removal` with ECR-shaped refusal text (`:34`, `:72-94`). The image-loss
guard is legitimate (INFRA-074); its placement is not — generic sequencing holds a provider
resource type, and GCP's `google_artifact_registry_repository.images` has no equivalent.

### AUDIT-POST-003 — provider identity as strings bypasses the dispatch ratchet (low)

`sol_cli_config.ml:283-288` maps six legacy flat target keys to the string literals `"aws"`/`"gcp"`.
The ratchet's regex matches only `Sol_cli_provider.Aws|Gcp` and `Aws_outputs|Gcp_outputs`
(`check_provider_dispatch.sh:48`); reproduced in `/tmp`: a file whose entire provider knowledge is
`Some ("aws", "aws")` reports "0 provider-dispatch occurrence(s)", while the same file written with
constructors is rejected (positive control). The instance is bounded, but the guard's guarantee is
weaker than claimed.

### AUDIT-POST-004 — platform-root operation state not guard-railed on destroy (low, safety family)

`guard_previous_operation` is called for the cloud root on apply and destroy
(`cmd_cloud_tf.ml:1030`, `:1219`) and for the platform root on apply (`:1037`), but never for the
platform root on destroy, although the destroy sequence runs platform init/apply
(`:1265`, `:1358`). A still-running platform operation therefore produces Terraform's backend-lock
error rather than Sol's `Running` report; the lock still prevents mutation.

### AUDIT-POST-005 — destroy-completeness guard misses `deletion_policy = "PREVENT"` (medium, safety family)

Rule 1 matches `prevent_destroy` (`:66-68`); rule 4 matches only `deletion_policy = "ABANDON"`,
`skip_destroy = true`, `skip_delete = true` (`:118-127`). Reproduced with a positive control: a copy
of the real GCP root passes; the same copy with `deletion_policy = "PREVENT"` on a well-formed bucket
also passes (rc 0), while the same mutation with a literal soft-delete retention is rejected. A root
could therefore make a target undeletable with no guard firing. No root uses it today.

### AUDIT-POST-006 — sensitive-variable parser assumes `terraform fmt` layout (low)

`Sol_cli_sensitive_vars.ml:10-31` requires the block header to end in `{` on one line and compares
the stripped line to exactly `sensitive=true`, so a trailing comment or a multi-line header is not
detected; `declared` fails closed only for an unreadable root (`:57-78`). No Terraform formatting
check runs in CI. The AWS/GCP roots are in fmt layout today, so there is no live leak.

### AUDIT-POST-007 — `sol_cli_credentials` is AWS-specific behind a generic name (low)

`cli/sol/lib/sol_cli_credentials.ml` is entirely AWS (`aws configure export-credentials`,
`AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN`, `aws sts get-caller-identity`); its only product caller
is `Sol_cli_aws_cluster:685`. GCP credentials live in `Sol_cli_gcp_cluster`. The generic name
misleads about where credentials are dispatched, though the actual selection point is
`Sol_cli_provider_registry.credentials`.

## Preserved invariants (all verified by reading + executing)

destroy never constructs; half-built targets stay destructible; Block/Continue; bracketed
elevation; the state-empty postcondition; retention observed rather than printed; non-Terraform
residue; Running/Resolved/Unresolved; `errored.tfstate` preserved and surfaced; never force-unlock;
never signal by process name; independent qualification inventory.

## Executed during the audit

`dune build`; `dune test cli/sol/test/` (exit 0, 56 suites incl. `supervised` 8/8); the offline
lifecycle harness directly (exit 0, 33 assertions, ends with the INFRA-075 canary); all
`internal/ci/*` guards and their mutation self-tests; `check_ocamlformat.sh --all`;
`dune test framework/` (14 failures, all schema-registry `Connection refused` — no local broker).
The real Sol home was byte-identical before and after (`runs/` = 21 entries), confirming INFRA-075
isolation.

## Closure

All seven findings are closed. Each ticket records problem, root cause, change, executable evidence
and its own canonical merge SHA (`git log --oneline -1 -- internal/pipeline/tickets/DONE/<ID>.md`).

| Finding | Ticket | Landed |
| --- | --- | --- |
| AUDIT-POST-001 | `AUDIT-POST-001.md` | #511 |
| AUDIT-POST-002 | `AUDIT-POST-002.md` | this PR |
| AUDIT-POST-003 | `AUDIT-POST-003.md` | this PR |
| AUDIT-POST-004 | `AUDIT-POST-004.md` | #510 |
| AUDIT-POST-005 | `AUDIT-POST-005.md` | #510 |
| AUDIT-POST-006 | `AUDIT-POST-006.md` | #510 |
| AUDIT-POST-007 | `AUDIT-POST-007.md` | #511 |

The closure pass was bounded to these seven: no architecture change, no provider-boundary redesign,
and nothing from the deleted Terraform ownership/verification model restored. The two guard holes the
audit reproduced are now closed *and* executable-guarded (`check_destroy_completeness.sh` classifies
every deletion semantic; `check_provider_dispatch.sh` rejects provider-native identity declarations
and provider names spelled as strings in a generic module, with the provider-implementation
exemption derived from the provider list rather than written out). The invariants listed above are
unchanged, and the Azure-on-paper surface is measured again at the end of the pass.
