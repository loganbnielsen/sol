type declared_certificate =
  { certificate : string
  ; namespace : string
  ; provenance : string
  }

let certificates =
  [ { certificate = "argocd-tls"
    ; namespace = "argocd"
    ; provenance =
        "the shared platform module's Argo CD ingress declares this TLS secret and \
         annotates itself with cert-manager.io/cluster-issuer, so Sol requests it on \
         every provider and every profile that applies the module (DEC-056)"
    }
  ; { certificate = "grafana-tls"
    ; namespace = "monitoring"
    ; provenance =
        "the shared platform module's Grafana ingress declares this TLS secret and \
         annotates itself with cert-manager.io/cluster-issuer, so Sol requests it on \
         every provider and every profile that applies the module (DEC-056)"
    }
  ]
;;

let describe () =
  String.concat
    "; "
    (List.map
       (fun (declared : declared_certificate) ->
          Printf.sprintf "%s/%s" declared.namespace declared.certificate)
       certificates)
;;
