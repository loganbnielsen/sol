type candidate =
  { address : string
  ; resource_class : string
  ; found : string
  ; import_identity : string
  }

type disposition =
  | Recover of candidate
  | Already_owned of
      { address : string
      ; found : string
      }
  | By_contract of
      { resource_class : string
      ; found : string
      }
  | Owned_through of
      { resource_class : string
      ; found : string
      ; owner : string
      ; reason : string
      }
  | Cannot_recover of
      { resource_class : string
      ; found : string
      ; reason : string
      }
  | Unmapped of
      { resource_class : string
      ; found : string
      }

val dispositions
  :  entries:Sol_cli_resource_identity.entry list
  -> class_rules:Sol_cli_resource_identity.class_rule list
  -> descendants:Sol_cli_resource_identity.descendant list
  -> state_addresses:string list
  -> Sol_cli_absence.observation list
  -> disposition list

val candidate : disposition -> candidate option
val outstanding : disposition list -> disposition list
val report : disposition list -> string
val summary : disposition list -> string
