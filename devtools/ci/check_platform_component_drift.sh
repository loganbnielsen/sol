#!/usr/bin/env bash
# Guardrail for docs/architecture/adr/0001-layer2-platform-component-source-of-truth.md
# (CODE_LAYER-005).
#
# Once a Helm value moves into cli/platform/components/<name>/values-*.json, it
# must not creep back as an independently hand-maintained literal in either
# execution layer -- that's exactly how BUG-013 (fixed in
# cli/platform/infra/base/main.tf only) turned into BUG-016 (cmd_local.ml still
# missing the fix). Deliberately a grep over a fixed key list, not an
# OCaml/HCL AST linter -- see the ADR's "No elaborate lint tooling" rule.
#
# This does not (and cannot, by grepping) prove a *value* is correct -- only
# that a key CODE_LAYER-005 already migrated hasn't reappeared as the exact
# dotted-string form the old `set { name = "..." }` / OCaml `~values:[...]`
# literals used (e.g. "loki.commonConfig.replication_factor"). KNOWN GAP:
# it will NOT catch the same value reintroduced as a nested HCL/OCaml object
# literal instead (e.g. `yamlencode({ loki = { commonConfig = {
# replication_factor = 3 } } })`) -- main.tf already uses that shape
# elsewhere (loki_infra_bindings, prometheus_thanos_server_fields), so it's
# a realistic way for drift to sneak back in undetected. Catching that would
# need real HCL/OCaml parsing, which the ADR explicitly rules out ("No
# elaborate lint tooling") -- reviewers should still eyeball new nested
# object literals touching a migrated component's resource for this.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cmd_local="$repo_root/cli/sol/bin/cmd_local.ml"
main_tf="$repo_root/cli/platform/infra/base/main.tf"

# Keys CODE_LAYER-005 moved into cli/platform/components/<name>/values-*.json,
# checked against both files. Keys intentionally still set inline in main.tf
# only (singleBinary.persistence.enabled, server.persistentVolume.enabled/
# retention -- var-driven Terraform-only knobs; prometheus-node-exporter.
# enabled -- a genuine dev-only literal main.tf never had) are deliberately
# absent from this list and checked separately below.
migrated_keys=(
  "deploymentMode"
  "singleBinary.replicas"
  "write.replicas"
  "read.replicas"
  "backend.replicas"
  "gateway.enabled"
  "loki.auth_enabled"
  "loki.commonConfig.replication_factor"
  "loki.storage.type"
  "loki.useTestSchema"
  "sidecar.dashboards.enabled"
  "sidecar.datasources.enabled"
  "pushgateway.enabled"
  "alertmanager.enabled"
  # CODE_LAYER-010 (Redpanda/PostgreSQL):
  "tls.enabled"
  "config.cluster.auto_create_topics_enabled"
  "auth.database"
)

# Keys that stay as legitimate, var-driven `set {}` blocks in main.tf (so
# they're NOT in migrated_keys above -- main.tf hardcoding them is correct,
# not drift) but whose cmd_local.ml copy now comes entirely from
# values-local.json, with no var to shadow it there. cmd_local.ml
# reintroducing either as an inline OCaml literal would silently duplicate
# what the JSON already provides -- exactly the BUG-013/BUG-016 pattern,
# just missed by migrated_keys since it's asymmetric across the two files.
cmd_local_only_keys=(
  "singleBinary.persistence.enabled"
  "server.persistentVolume.enabled"
  # CODE_LAYER-010 (Redpanda): main.tf keeps its own var-driven nested
  # HCL attributes (statefulset.replicas, resources.cpu.cores) for these
  # -- not a `set {}` dotted-string block, so main.tf was never checked
  # for these anyway, but cmd_local.ml must not reintroduce them inline
  # (they're only in values-local.json, not values-common.json, so this
  # guardrail's shared migrated_keys list above doesn't cover them).
  #
  # storage.persistentVolume.size and cmd_local.ml's external.*/
  # listeners.kafka.* block are deliberately NOT here or in any
  # cli/platform/components/redpanda/*.json file at all -- see cmd_local.ml's
  # own comment on its Redpanda install (adversarial review on
  # CODE_LAYER-010 caught that putting them in the shared local.json
  # would have silently shipped dev-only values, a 1Gi PVC size and a
  # "localhost"-advertised external listener, to real clusters, since
  # main.tf's helm_release.redpanda never overrides either). They're
  # plain OCaml `~values` literals, same category as
  # prometheus-node-exporter.enabled above -- not tracked by this
  # guardrail at all, precisely because there's no shared file for them
  # to drift out of sync with.
  "statefulset.replicas"
  "resources.cpu.cores"
  # CODE_LAYER-010 (PostgreSQL): main.tf keeps its own var-driven `set`
  # for both -- a real secret (auth.postgresPassword) and the same
  # persistence-knob pattern as Loki/Prometheus above.
  "auth.postgresPassword"
  "primary.persistence.enabled"
)

fail=0

for key in "${migrated_keys[@]}"; do
  if grep -qF "\"${key}\"" "$cmd_local"; then
    echo "guardrail: $cmd_local hardcodes \"${key}\" inline again -- this value belongs in cli/platform/components/<name>/values-*.json (ADR 0001 / CODE_LAYER-005)." >&2
    fail=1
  fi
  if grep -qF "\"${key}\"" "$main_tf"; then
    echo "guardrail: $main_tf hardcodes \"${key}\" inline again -- this value belongs in cli/platform/components/<name>/values-*.json (ADR 0001 / CODE_LAYER-005)." >&2
    fail=1
  fi
done

for key in "${cmd_local_only_keys[@]}"; do
  if grep -qF "\"${key}\"" "$cmd_local"; then
    echo "guardrail: $cmd_local hardcodes \"${key}\" inline again -- this value now comes entirely from cli/platform/components/<name>/values-local.json (ADR 0001 / CODE_LAYER-005); main.tf legitimately keeps its own var-driven \`set\` for this key, but cmd_local.ml has no such var and must not duplicate it." >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "guardrail: no migrated platform-component keys found duplicated inline in cmd_local.ml or main.tf."
fi

exit "$fail"
