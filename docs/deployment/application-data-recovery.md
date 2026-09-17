# Application data recovery

This runbook covers the application-data contract of
`production-single-region/v1`. Qualification evidence belongs in HARDEN-002;
the commands below are the operator procedure, not proof that a target passed.

## PostgreSQL

The qualified AWS path provisions encrypted RDS PostgreSQL with Multi-AZ,
seven days of automated backups, and point-in-time recovery. Multi-AZ handles
infrastructure failover; it does not undo logical deletion or a bad migration.

For logical recovery:

1. Stop writes to the affected application and record the incident time.
2. Choose a restore time no later than the last known-good application write.
3. Restore to a new instance; never overwrite the affected database:

   ```sh
   aws rds restore-db-instance-to-point-in-time \
     --source-db-instance-identifier "$SOURCE_DB" \
     --target-db-instance-identifier "$RESTORE_DB" \
     --restore-time "$RESTORE_TIME" \
     --no-publicly-accessible
   ```

4. Wait for `DBInstanceStatus=available`, attach the target's private database
   security group if the restore did not inherit it, and connect from the
   qualification runner.
5. Run the application's migrations in validation mode, its database-backed
   integration tests, and an application-owned integrity query that checks
   expected row counts and domain invariants. Provider job completion alone is
   not successful recovery.
6. Record the newest recovered application timestamp (RPO), elapsed time from
   restore request to passed integrity checks (RTO), source/target identifiers,
   and test output. HARDEN-002 requires RPO at most five minutes and RTO at most
   60 minutes.
7. Cut over credentials only after integrity checks pass. Retain the affected
   instance for investigation; deletion follows the incident retention policy.

For infrastructure-failure qualification, induce failover with
`aws rds reboot-db-instance --force-failover`, verify application reconnect
behavior, and record the interval until successful application requests resume.
The profile target is RPO approximately zero and RTO under two minutes.

## Redpanda

The qualified path uses three brokers, topic replication factor three,
producer `acks=all`, and disabled write caching. Existing topics with fewer
than three replicas are rejected by framework startup instead of being treated
as conformant. HARDEN-002 removes one broker, verifies zero loss from an
application-produced acknowledged sequence, and measures consumer recovery
against the 60-second bound.

Whole-cluster restore is outside this profile. Simultaneous multi-broker loss
is also excluded.

## Workload volumes

`production-single-region/v1` admits a workload volume only for a `single`
workload. It claims the backing store's ordinary single-AZ durability, with no
backup or restore guarantee. If the volume is lost, replace the workload and
volume from the application artifact and rehydrate data from an application-
owned upstream source where one exists. A workload requiring volume backup or
point-in-time restore is not conformant with this profile.
