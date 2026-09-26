# AWS qualification Run 6, attempt 6 — 2026-09-19

> Moved verbatim on 2026-09-24 from `internal/pipeline/tickets/READY_FOR_ENGINEERING/HARDEN-002.md` (lines 936–1001 at `a9d7d827`), when the HARDEN-002 epic was closed as a ticket and its run history moved into the qualification ledger. Headings keep their original levels; the text is unchanged. Index: `internal/qualification/README.md`.

## Run 6 attempt 6 (executed 2026-09-19) — the application-centric attempt

**Platform: CONFORMANT for the second consecutive time.** Authority
`main @ 0791a825`; the binary was verified to carry INFRA-037/038/039, DEC-033 and
HARDEN-003. Target `sol-qual10-31012e41` with `destroy_retention: none`.

```text
credentials: arn:aws:iam::…:user/Administrator   <- INFRA-039, first live use
lifecycle phase: CloudBootstrap      [terraform-apply] ok (888.1s)
lifecycle phase: PlatformInstalling  prerequisites ok / platform-apply ok (182.7s)
provisioner-bootstrap-access-remove  ok (11.6s)
lifecycle phase: Ready               Done.
```

Infrastructure construction has become uneventful, which is the point: the
interesting failures have moved up a layer, exactly as expected.

**INFRA-039 proved itself before the run.** `sol-qual`'s SSO refresh token is
expired, so `aws configure export-credentials --profile sol-qual` failed *up front*
and the run used the static `Administrator` profile. On Attempt 5 that same
condition surfaced as a destroy that could not authenticate against a billable
target.

**INFRA-038 proved itself live.** `sol deploy --scope checkout/checkout_svc`
reached `Profile: production-single-region/v1 (preflight passed)` — the scope that
Attempt 5 could not get past preflight at all.

### Blocking finding: no workload can be deployed (INFRA-040)

The deploy failed at the migration gate with "migration-status Job did not complete
within 120s". Re-running the remedy it prescribed showed the real cause, which the
deploy's own message hid: the migration Job's container uses
`envFrom: secretRef{name: sol-secrets}`, while the substrate creates
`sol-secrets-secrets` — the right keys under the wrong name. So migrations can never
run and **no Sol workload can be deployed to a cloud target**. Filed as INFRA-040,
including the two diagnostics gaps that made it cost a second command to see (a
timeout reported instead of a failed container; the Job deleted with its reason;
a remedy that accepts no `--scope`).

### Second finding: DEC-033 does not reach the destroy (INFRA-041)

`destroy_retention: none` was ignored: the destroy took a final snapshot and printed
no retention report, so cost-clean again needed a manual deletion — the deviation
DEC-033 existed to remove. Filed with the test gap that let it through (the model
was tested; the config path and the destroy path were not).

### Teardown and absence (independent)

Documented lifecycle: prepare → `PreparingDestroy` → platform-destroy → `Destroying`
→ `terraform-destroy` ok → `Done.` Verification: EKS none, RDS 0, EC2 4 terminated,
NAT deleted, EIP/LB/EBS/VPC/ECR none, CloudWatch log groups 0. One stray manual
snapshot remained and was deleted by hand (the INFRA-041 deviation).

### Deviations

1. `Administrator` (static) rather than the SSO profile, because the SSO refresh
   token is expired. The failure was detected up front, not mid-teardown.
2. The local Docker config carried `credsStore: desktop.exe`, which fails for
   non-interactive processes in this WSL setup; `docker push` from the deploy
   therefore failed with a credential-helper error. Removed from the local config
   (Sol passes the environment through unchanged — verified — so this is
   environmental, not a product defect).
3. `SOL_API_KEY` is required by the workspace's substrate Secret and is not
   mentioned in the deploy step of this procedure.
4. The stray final snapshot was deleted by hand.
