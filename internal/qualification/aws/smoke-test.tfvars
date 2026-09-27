base_domain = "smoke-test.invalid"

node_instance_types = ["t3.medium"]
node_min_size       = 2
node_max_size       = 2
node_desired_size   = 2

ha_nat_gateway = false

rds_deletion_protection = false

rds_skip_final_snapshot = true

create_route53_zone = false

ecr_repositories = []
