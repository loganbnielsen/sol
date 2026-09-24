# FND-0048 — `gcp_protection_state` identifies guarded resources by type in the root module, and mislabels an empty state as unreadable

- **Classification:** `VERIFIED_DEFECT`, against FND-0030's design ("the targeted list must
  come from `terraform state list`")
- **State:** `OPEN`
- **First identified:** 2026-09-23, by a second reviewer at `main @ f2e1773`; re-verified at
  `origin/main @ f3e9480b`
- **Derived ticket:** `INFRA-071`
- **Evidence class:** `STATIC`

## What is established

`gcp_protection_state` (`cli/sol/bin/cmd_cloud_tf.ml:1789-1812`) reads `terraform show -json`,
takes `values.root_module.resources`, and for each guarded **type** takes the first resource
of that type. `gcp_guarded_resources` (`:1822-1826`) then maps "a resource of this type
exists" onto a fixed **address** (`google_sql_database_instance.postgres`,
`google_container_cluster.main`).

- **Type is not address.** It misses resources in child modules. With a second instance of
  the same type (say a read replica), it reads whichever comes first and attributes it to
  the fixed address.
- **An empty state is reported as a read failure.** With no `values` key, `member
  "root_module"` on `Null` raises `Type_error`, which becomes *"unexpected `terraform show
  -json` shape"*. A null `deletion_protection` makes `to_bool` raise the same way. A
  legitimately empty or half-built state, the case FND-0030 exists for, is labelled
  "could not read state".

## Remedy shape

Build `represented` from actual addresses (`terraform state list`, or walking
`root_module` and `child_modules` with `address`). Treat an absent `values` as the empty
state. Read `deletion_protection` as `bool option`. This naturally shares FND-0045's state
inventory.

## Related

FND-0030 (#451), FND-0044, FND-0045.
