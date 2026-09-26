(** Reads shared platform-component desired state from
    [platform/shared/components.json] (ADR 0001 / CODE_LAYER-005, REFAC-102) so
    [sol local infra up] and [platform/cloud/modules/platform/main.tf]'s [helm_release]
    resources stop hand-duplicating the same Helm values. *)

(** [merged_values_yaml ~component ~profile] reads [<component>.common] and
    [<component>.<profile>] from [platform/shared/components.json], deep-merges
    the profile layer over common (profile wins on key conflicts; nested objects
    merge recursively, other conflicts take the profile's value outright), and
    returns the merged document as JSON text. JSON is valid YAML, so this is
    suitable as-is for {!Sol_cli_helm.upgrade_install}'s [?values_yaml].

    A layer the file does not name (a component with nothing to say for that
    profile, or a component it does not list) is an empty object, not an error.
    An [Error] says why [components.json] is missing or unreadable (REFAC-115). *)
val merged_values_yaml
  :  assets:Sol_cli_platform_assets.t
  -> component:string
  -> profile:string
  -> (string, string) result
