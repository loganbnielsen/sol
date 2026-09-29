open Sol_cli_absence

type check =
  { resource_class : string
  ; identity : string
  ; attribution : attribution
  ; argv : string list
  ; attributable : string -> bool
  }

let check ?(attributable = fun _ -> true) ~resource_class ~identity ~attribution argv =
  { resource_class; identity; attribution; argv; attributable }
;;

let lines output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
;;

let checked_with argv = "aws " ^ String.concat " " argv

let not_found reason =
  [ "notfound"; "not found"; "does not exist"; "no such" ]
  |> List.exists (fun needle ->
    Sol_cli_string.contains ~needle (String.lowercase_ascii reason))
;;

let run ~check =
  match Sol_cli_process.run (Sol_cli_process.cmd ("aws" :: check.argv)) with
  | Ok { Sol_cli_process.stdout; _ } ->
    let checked_with = checked_with check.argv in
    (match lines stdout |> List.filter check.attributable with
     | [] ->
       Absent
         { resource_class = check.resource_class
         ; identity = check.identity
         ; attribution = check.attribution
         ; checked_with
         }
     | found ->
       Present
         { resource_class = check.resource_class
         ; identity = check.identity
         ; found
         ; attribution = check.attribution
         ; checked_with
         })
  | Error (Sol_cli_process.Non_zero r) when not_found r.stderr ->
    Absent
      { resource_class = check.resource_class
      ; identity = check.identity
      ; attribution = check.attribution
      ; checked_with =
          Printf.sprintf
            "%s (the provider reports it does not exist: %s)"
            (checked_with check.argv)
            (String.trim r.stderr)
      }
  | Error (Sol_cli_process.Non_zero r) ->
    Unobservable
      { resource_class = check.resource_class
      ; reason = String.trim r.stderr
      ; checked_with = checked_with check.argv
      }
  | Error _ ->
    Unobservable
      { resource_class = check.resource_class
      ; reason = "the aws CLI is unavailable"
      ; checked_with = checked_with check.argv
      }
;;

let named_for_cluster cluster_name =
  Printf.sprintf
    "the target's own cluster name: the target's roots name the resources they create \
     after %s"
    cluster_name
;;

let registry_prefix (target : Sol_cli_config.target) =
  match target.registry with
  | None -> None
  | Some registry ->
    (match String.index_opt registry '/' with
     | None -> None
     | Some index ->
       let prefix =
         String.sub registry (index + 1) (String.length registry - index - 1)
       in
       if prefix = "" then None else Some prefix)
;;

let cluster_tagged ~region ~cluster_name class_name query =
  let tag =
    Printf.sprintf "Name=tag:kubernetes.io/cluster/%s,Values=owned,shared" cluster_name
  in
  check
    ~resource_class:class_name
    ~identity:(Printf.sprintf "tagged kubernetes.io/cluster/%s" cluster_name)
    ~attribution:
      (Within_target
         (Printf.sprintf
            "the target's own cluster tag: %s marks what this cluster's controllers \
             created,              and Sol writes it itself"
            cluster_name))
    ~attributable:(fun line -> line <> "")
    (match class_name with
     | "VPC" | "subnet" ->
       [ "ec2"
       ; (if class_name = "VPC" then "describe-vpcs" else "describe-subnets")
       ; "--region"
       ; region
       ; "--filters"
       ; tag
       ; "--query"
       ; query
       ; "--output"
       ; "text"
       ]
     | "load balancer" ->
       [ "elbv2"
       ; "describe-load-balancers"
       ; "--region"
       ; region
       ; "--filters"
       ; tag
       ; "--query"
       ; query
       ; "--output"
       ; "text"
       ]
     | _ ->
       [ "ec2"
       ; "describe-volumes"
       ; "--region"
       ; region
       ; "--filters"
       ; tag
       ; "--query"
       ; query
       ; "--output"
       ; "text"
       ])
;;

let checks ~region ~cluster_name =
  let prefixed_class ~resource_class ~prefix argv =
    check
      ~resource_class
      ~identity:(prefix ^ "*")
      ~attribution:(Named_for_target (named_for_cluster cluster_name))
      ~attributable:(fun line -> Sol_cli_string.contains ~needle:prefix line)
      argv
  in
  [ check
      ~resource_class:"EKS cluster"
      ~identity:cluster_name
      ~attribution:(Named_for_target (named_for_cluster cluster_name))
      ~attributable:(fun line -> Sol_cli_string.contains ~needle:cluster_name line)
      [ "eks"
      ; "list-clusters"
      ; "--region"
      ; region
      ; "--query"
      ; "clusters[]"
      ; "--output"
      ; "text"
      ]
  ; check
      ~resource_class:"EKS node group"
      ~identity:cluster_name
      ~attribution:(Within_target "an EKS node group of the target's own cluster")
      ~attributable:(fun line -> line <> "")
      [ "eks"
      ; "list-nodegroups"
      ; "--cluster-name"
      ; cluster_name
      ; "--region"
      ; region
      ; "--query"
      ; "nodegroups[]"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"RDS instance"
      ~prefix:(cluster_name ^ "-postgres")
      [ "rds"
      ; "describe-db-instances"
      ; "--region"
      ; region
      ; "--query"
      ; "DBInstances[].DBInstanceIdentifier"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"RDS subnet group"
      ~prefix:(cluster_name ^ "-postgres")
      [ "rds"
      ; "describe-db-subnet-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "DBSubnetGroups[].DBSubnetGroupName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"security group"
      ~prefix:(cluster_name ^ "-rds")
      [ "ec2"
      ; "describe-security-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "SecurityGroups[].GroupName"
      ; "--output"
      ; "text"
      ]
  ; cluster_tagged ~region ~cluster_name "VPC" "Vpcs[].VpcId"
  ; cluster_tagged ~region ~cluster_name "subnet" "Subnets[].SubnetId"
  ; prefixed_class
      ~resource_class:"IAM role"
      ~prefix:(cluster_name ^ "-")
      [ "iam"; "list-roles"; "--query"; "Roles[].RoleName"; "--output"; "text" ]
  ; prefixed_class
      ~resource_class:"IAM policy"
      ~prefix:(cluster_name ^ "-")
      [ "iam"
      ; "list-policies"
      ; "--scope"
      ; "Local"
      ; "--query"
      ; "Policies[].PolicyName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"S3 bucket"
      ~prefix:(cluster_name ^ "-")
      [ "s3api"; "list-buckets"; "--query"; "Buckets[].Name"; "--output"; "text" ]
  ; prefixed_class
      ~resource_class:"CloudWatch dashboard"
      ~prefix:(cluster_name ^ "-")
      [ "cloudwatch"
      ; "list-dashboards"
      ; "--region"
      ; region
      ; "--query"
      ; "DashboardEntries[].DashboardName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"EKS control-plane log group"
      ~prefix:("/aws/eks/" ^ cluster_name)
      [ "logs"
      ; "describe-log-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "logGroups[].logGroupName"
      ; "--output"
      ; "text"
      ]
  ; cluster_tagged
      ~region
      ~cluster_name
      "load balancer"
      "LoadBalancers[].LoadBalancerName"
  ; cluster_tagged ~region ~cluster_name "EBS volume" "Volumes[].VolumeId"
  ]
;;

let durable_observations ~(target : Sol_cli_config.target) =
  [ External
      { resource_class = "Terraform state bucket"
      ; identity = "(the durable backend for this target)"
      ; reason =
          "the state bucket is explicitly durable and outside the target's disposable \
           surface: Sol documents that it survives destroy, so its presence is the \
           contract, not residue"
      }
  ; External
      { resource_class = "Route 53 hosted zone"
      ; identity = Option.value target.base_domain ~default:"(the target's base domain)"
      ; reason =
          "a delegation zone is published by the operator and outlives the target, so \
           its presence is the contract, not residue"
      }
  ]
;;

let class_names =
  [ "EKS cluster"
  ; "EKS node group"
  ; "RDS instance"
  ; "RDS subnet group"
  ; "security group"
  ; "VPC"
  ; "subnet"
  ; "IAM role"
  ; "IAM policy"
  ; "S3 bucket"
  ; "CloudWatch dashboard"
  ; "EKS control-plane log group"
  ; "load balancer"
  ; "EBS volume"
  ; "ECR repository"
  ]
;;

let ecr_observation ~region ~registry =
  match registry with
  | Some prefix ->
    run
      ~check:
        (check
           ~resource_class:"ECR repository"
           ~identity:(prefix ^ "/*")
           ~attribution:
             (Named_for_target
                (Printf.sprintf
                   "the target's own registry path: the cluster root names its \
                    repositories under %s, which the target declares"
                   prefix))
           ~attributable:(fun line -> Sol_cli_string.contains ~needle:(prefix ^ "/") line)
           [ "ecr"
           ; "describe-repositories"
           ; "--region"
           ; region
           ; "--query"
           ; "repositories[].repositoryName"
           ; "--output"
           ; "text"
           ])
  | None ->
    Not_attributable
      { resource_class = "ECR repository"
      ; reason =
          "the target declares no registry, so Sol cannot say which repositories under \
           this account belong to it -- reported rather than guessed"
      }
;;

let observations (target : Sol_cli_config.target) ~cluster_name =
  List.map (fun c -> run ~check:c) (checks ~region:target.region ~cluster_name)
  @ [ ecr_observation ~region:target.region ~registry:(registry_prefix target) ]
  @ durable_observations ~target
;;

let unresolved ~reason =
  [ Unobservable
      { resource_class = "the provider inventory"
      ; reason
      ; checked_with = "(not run: the target could not be identified)"
      }
  ]
;;
