# Custom target Terraform

For AWS or GCP targets, put root `.tf` files in
`sol/terraform/<provider>/cluster/` or `sol/terraform/<provider>/platform/`.
Files in `modules/` under either root are available to local Terraform module
blocks. `sol plan` and `sol deploy` compose these files into the matching Sol
Terraform root, so your resources share its dependency graph and state.

Custom configuration may use the documented `local.sol_target` values. Do not
depend on generated Terraform module or resource addresses. Declare Terraform
`output` blocks for values your own configuration needs to publish. See the
Substrate reference for the supported values and root boundaries.
