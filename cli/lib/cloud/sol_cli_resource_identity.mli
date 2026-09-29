type ownership =
  | Direct
  | Direct_not_recoverable of string
  | In_cluster of string
  | Synthetic of string
  | External_by_contract of string
  | Through_owner of
      { owner : string
      ; reason : string
      }

type source =
  | Root
  | Module of string

type entry =
  { address : string
  ; source : source
  ; resource_class : string
  ; observed_as : string
  ; ownership : ownership
  ; identity : string
  ; import_identity : string
  }

type type_rule =
  { terraform_type : string
  ; ownership : ownership
  }

type descendant =
  { resource_class : string
  ; owner : string
  ; reason : string
  }

val gcp : cluster_name:string -> entry list
val aws : cluster_name:string -> entry list

type class_rule =
  { resource_class : string
  ; ownership : ownership
  }

val type_rules : type_rule list
val class_rules : class_rule list
val descendants : cluster_name:string -> descendant list
val ownership_kind : ownership -> string
val ownership_reason : ownership -> string
val is_direct : entry -> bool
val recoverable : entry -> bool
