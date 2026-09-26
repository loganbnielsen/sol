(* INFRA-090: Sol's own declaration of the persistent disk the platform needs.

   This is the *demand* half of the disk-quota check, and it is deliberately Sol's, not the
   provider's: the provider says how much quota exists and how much is already spent, and Sol
   says what it is going to ask for. What it is *not* is a prediction of the provider's
   footprint -- Attempt 12's whole lesson was that the cluster's own consumption is whatever it
   has already made, which is why the check runs after the cluster exists and reads the
   provider's usage rather than modelling anyone's node count.

   It is a **minimum**, and the check treats it as a floor: a project with room for this may
   still refuse a *larger* platform if the platform's declarations grow, which is why the parts
   carry their provenance and are checked against those declarations by
   `internal/ci/check_platform_storage_requirement.sh`.

   The parts are the platform components Sol installs that ask for a PersistentVolumeClaim: *)

type part =
  { component : string
  ; gib : int
  ; provenance : string (** where the number comes from, so a reader can check it *)
  }

let parts =
  (* Every size here is the *chart's* default, not Sol's: Sol declares that persistence is
     enabled (`var.prometheus_persistent_storage`, loki's `singleBinary.persistence.enabled`)
     and sets no size, so the request comes from the chart. The numbers were read from the live
     cluster in GCP Attempt 12, where they were the three claims that could not bind. A chart
     that changes a default changes the requirement, which is why a green
     `check_platform_storage_requirement.sh` only proves the parts are still declared and the
     persistence still enabled -- the sizes need a live observation to confirm, and that is
     what the run's own inventory is for. *)
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
