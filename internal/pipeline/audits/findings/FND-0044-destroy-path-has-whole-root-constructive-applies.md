# FND-0044 — The destroy path still runs whole-root constructive applies after the targeted preparation, and decides "substrate exists" with the install-time outputs contract

- **Classification:** `VERIFIED_DEFECT`, against FND-0030's recorded design ("zero create
  operations during recovery"; "the targeted apply is the only constructive step in the
  destroy path")
- **State:** `FIXED_UNQUALIFIED` (2026-09-24 — fixed by HARDEN-004 parts 2–3, #462/#463; see the transition at the end of this file)
- **First identified:** 2026-09-23, by a second reviewer (another agent) at `main @ f2e1773`;
  re-verified in this audit at `origin/main @ f3e9480b` (#452 merged, unchanged)
- **Derived ticket:** `INFRA-068`
- **Evidence class:** `STATIC`. The offline replay named below would make it `MECHANISM`.

## What is established

**1. Two whole-root applies follow the preparation.** `cloud_destroy`
(`cli/sol/bin/cmd_cloud_tf.ml:2649`), in the `Apply` branch, after `prepare_destruction`:

- `:2906-2916` — `destroy-reconciliation-apply`: `Sol_cli_terraform.apply ~scope:whole_root`
  with `bootstrap_access_vars ~enabled:true @ vars @ destroy_vars`;
- `:2919-2925` — `provisioner-bootstrap-access-remove`: another `whole_root` apply.

A whole-root apply creates every configured resource missing from state. In the Attempt-6
shape (cluster present in the provider, absent from state), #451's preparation correctly
skips the cluster, and the very next step plans to create it. The result is either the same
`409 Already exists`, or, if the cluster really is gone, Sol creating a GKE cluster in order
to delete it. FND-0030's text (`:78-83`) says the targeted apply is the only constructive
step. That is false.

**2. "Substrate exists" is read through the install-time contract.** Both applies run only
when `outputs` is `Some` (`:2899-2900`). `gcp_outputs` (`:698-712`) maps `{}` to `None`, and
anything else goes through `gcp_outputs_of_json`
(`cli/sol/lib/sol_cli_cloud_lifecycle.ml:211-245`), which **requires** `cluster_name`,
`project_id`, `region`, `artifact_registry` and `provisioner_service_account`. For a
half-built state, that gives three cases:

| Outputs in the half-built state | What destroy does |
|---|---|
| `{}` | "substrate absent": preparation and reconciliation skipped (works by accident) |
| partial (e.g. `project_id`/`region` from variables, `cluster_name` unresolved) | parse error, then `lifecycle_error`: **destroy refused before anything runs** (INFRA-067's class through another door) |
| complete | the whole-root applies run and try to create what is missing (point 1) |

Two of the three fail.

## Not established

Which case the frozen Attempt-6 state is in. It can be settled offline and for free: run
`terraform output -json` and `terraform plan` (with `destroy_apply_vars` + bootstrap-enabled)
against a copy of that state. A pure function *"given this state JSON, what does destroy
do"* would let every recorded attempt be replayed the same way.

## Remedy shape

Plan-and-assert on **every** apply in the destroy path: no `create`/`replace` except an
explicit allowlist, namely the bootstrap-access window resource, which is legitimately a
create. Scope the reconciliation apply to that resource plus the eligible guarded
resources, not `whole_root`. Decide "substrate exists" from state (`terraform state list`),
not from install-time outputs.

## History

- 2026-09-23 — filed; FND-0030 annotated with a dated correction of its
  "only constructive step" claim.

## Related

FND-0030, INFRA-067, ADR 0003 invariant 6, DEC-040; FND-0045 (single state inventory).

## Transition (2026-09-24) — fixed offline; the replay was ruled out, not run

- **Point 1 (whole-root constructive applies)** — fixed by HARDEN-004 part 3 (#463): every
  destroy-path apply is planned to a saved plan and refused before it runs when a change is
  outside its phase allowlist; reconciliation is scoped to the bootstrap mechanism plus the guarded
  addresses state represents. Pinned by `test_terraform_plan.ml`
  (`test_whole_root_missing_cluster_create_is_refused`, "Attempt-6 inventory prunes the scope")
  and the offline harness's refusal scenario.
- **Point 2 (existence from install outputs)** — fixed by HARDEN-004 part 2 (#462): substrate
  existence comes from the typed state inventory.
- **"Not established" above** — the offline replay of the frozen Attempt-6 state was **ruled out**
  (#461, `HARDEN-004-handoff.md` "Step 1"): the frozen evidence is logs only, and a `plan` against
  the real backend is a network operation on the qualification project. It stays not established.
  The lesson — pull state before any teardown — is recorded in `docs/qualification/README.md`.
- `FIXED_UNQUALIFIED`, not `QUALIFIED`: the evidence is offline. INFRA-068 moves to `DONE`.

