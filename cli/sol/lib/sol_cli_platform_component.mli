(** Reads shared platform-component desired state from
    [cli/platform/components/<component>/] (ADR 0001 / CODE_LAYER-005) so
    [sol dev up] and [cli/platform/infra/base/main.tf]'s [helm_release] resources
    stop hand-duplicating the same Helm values. *)

(** [merged_values_yaml ~component ~profile] reads
    [cli/platform/components/<component>/values-common.json] and
    [values-<profile>.json], deep-merges the profile file over common
    (profile wins on key conflicts; nested objects merge recursively, other
    conflicts take the profile's value outright), and returns the merged
    document as JSON text. JSON is valid YAML, so this is suitable as-is for
    {!Sol_cli_helm.upgrade_install}'s [?values_yaml].

    A missing file (a component with nothing to say for that layer, e.g.
    [tempo]'s empty profiles) is treated as an empty object, not an error.
    Exits with an error message if the Sol monorepo root can't be located
    (same resolution as [sol cloud plan/apply], see
    {!Sol_cli_cmd_new.infer_sol_home}) or if a values file exists but isn't
    valid JSON. *)
val merged_values_yaml : component:string -> profile:string -> string
