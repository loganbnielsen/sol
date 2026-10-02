let non_zero ?(stdout = "") stderr =
  Sol_cli_process.Non_zero { exit_code = 1; stdout; stderr }
;;

let reason = function
  | Sol_cli_gcloud.Not_found -> "Not_found"
  | Sol_cli_gcloud.Other -> "Other"
;;

let check_reason label expected actual =
  Alcotest.(check string) label (reason expected) (reason actual)
;;

let test_gcloud () =
  check_reason
    "clusters describe 404"
    Not_found
    (Sol_cli_gcloud.classify
       (non_zero
          "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, \
           message=Not found: projects/p/locations/r/clusters/c."));
  check_reason
    "compute's was-not-found under the generic prefix"
    Not_found
    (Sol_cli_gcloud.classify
       (non_zero
          "ERROR: (gcloud.compute.instances.describe) Could not fetch resource:\n\
          \ - The resource 'projects/p/zones/z/instances/i' was not found"));
  check_reason
    "a 403 under the same prefix is not absence"
    Other
    (Sol_cli_gcloud.classify
       (non_zero
          "ERROR: (gcloud.compute.instances.describe) Could not fetch resource:\n\
          \ - Required 'compute.instances.get' permission for \
           'projects/p/zones/z/instances/i'"));
  check_reason
    "a not-found about another project is not absence"
    Other
    (Sol_cli_gcloud.classify
       ~project:"ours"
       (non_zero "ERROR: code=404 Not found: projects/theirs/x"));
  check_reason
    "a timeout is not absence"
    Other
    (Sol_cli_gcloud.classify (Sol_cli_process.Timeout 30.));
  check_reason
    "gcloud missing is not absence"
    Other
    (Sol_cli_gcloud.classify (Sol_cli_process.Spawn_failed "gcloud: not found"))
;;

let test_aws () =
  Alcotest.(check (option string))
    "the service code"
    (Some "DBSnapshotNotFound")
    (Sol_cli_aws.error_code
       "An error occurred (DBSnapshotNotFound) when calling the DescribeDBSnapshots \
        operation: DBSnapshot sol-final not found.");
  Alcotest.(check (option string))
    "a dotted code"
    (Some "InvalidDBInstanceId.NotFound")
    (Sol_cli_aws.error_code
       "An error occurred (InvalidDBInstanceId.NotFound) when calling the \
        DescribeDBInstances operation: ...");
  Alcotest.(check (option string))
    "no code in a client-side failure"
    None
    (Sol_cli_aws.error_code "Unable to locate credentials. You can configure credentials")
;;

let%test "REFAC-136: gcloud" = test_gcloud ()
let%test "REFAC-136: aws" = test_aws ()
