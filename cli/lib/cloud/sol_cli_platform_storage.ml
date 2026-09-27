type part =
  { component : string
  ; gib : int
  ; provenance : string
  }

let parts =
  [ { component = "prometheus server"
    ; gib = 8
    ; provenance =
        "chart default for the prometheus server's persistence size (observed live as \
         8Gi in GCP Attempt 12); Sol enables it through \
         var.prometheus_persistent_storage and sets no size"
    }
  ; { component = "prometheus alertmanager"
    ; gib = 2
    ; provenance =
        "chart default for alertmanager's persistence size (observed live as 2Gi in GCP \
         Attempt 12); Sol enables persistence and sets no size"
    }
  ; { component = "loki (single binary)"
    ; gib = 10
    ; provenance =
        "chart default for Loki's singleBinary.persistence size (observed live as 10Gi \
         in GCP Attempt 12); Sol enables persistence through \
         singleBinary.persistence.enabled and sets no size"
    }
  ]
;;

let minimum_gb = List.fold_left (fun total part -> total + part.gib) 0 parts

let describe () =
  String.concat
    "; "
    (List.map (fun p -> Printf.sprintf "%s %d GiB" p.component p.gib) parts)
;;
