# Operations, recovery and troubleshooting

## Release behavior

The deployment is a **stop/start deployment with brief downtime**, not blue/green. The old container stops before the replacement opens SQLite. One Gunicorn worker with four threads avoids startup races in the SQLite-persisted secret key. The filesystem is read-only except the EBS data mount and temporary files; the process is non-root and all Linux capabilities are dropped.

The host script uses a lock to serialize deployment. GitHub concurrency separately serializes app releases per branch. Infra changes and app releases are different repository locks: schedule them separately in a maintenance window; do not change EC2/storage during an app release.

## Diagnostics

Use an authorized SSO operator identity and Systems Manager Session Manager. CI has Run Command permission; it is not a general workstation credential. No SSH key or port 22 is configured.

```bash
aws ssm start-session --region ap-south-1 --target i-YOURINSTANCE
sudo cloud-init status --long
sudo tail -n 100 /var/log/cloud-init-output.log
sudo systemctl status docker amazon-ssm-agent amazon-cloudwatch-agent
sudo lsblk -f
sudo findmnt /opt/autoapp/data
sudo df -h / /opt/autoapp/data
sudo docker ps -a
sudo docker inspect --format '{{.State.Health.Status}}' autoapp
sudo ss -lntp | rg 5080
curl -fsS http://127.0.0.1:5080/healthz
```

Container output goes to CloudWatch `/autoapp/dev` or `/autoapp/production`, stream `portal`. Use CloudWatch rather than depending on `docker logs` support for the awslogs driver. `aws logs tail /autoapp/dev --follow --region ap-south-1` requires the operator to have log read permissions.

| Symptom | Check |
|---|---|
| OIDC AccessDenied | Exact repo/environment `sub`, audience, account role ARN, environment branch restrictions |
| SSM instance offline | cloud-init, SSM service, instance profile, private route/NAT, HTTPS egress |
| ECR pull fails | Account/region/repository URL, instance IAM, NAT/DNS, image digest exists |
| Data disk unavailable | Terraform attachment, exact EBS volume serial, AZ, mount and UUID; never format a guessed NVMe disk |
| Container starts then exits | CloudWatch traceback, UID 1000 write access to data, immutable dependency compatibility, memory |
| Host health passes, ALB fails | Target group port/path, ALB SG → EC2 SG reference, instance registration |
| Browser TLS error | DNS name must match ACM certificate, validated cert in correct region |
| Login redirects/SSO URL wrong | HTTPS, Secure cookies, ALB forwarded protocol; application directly reachable only from ALB SG |
| Metrics missing | Agent startup, metric permission/namespace, restart agent after EBS first mount |
| Scan AccessDenied | Base instance role intentionally has no AWS inventory rights; review target role trust/actions |
| Terraform locked | Check active Actions run; do not force-unlock a live apply |

After the first data mount, restart `amazon-cloudwatch-agent` and confirm both root and data filesystem metrics. Aggregate disk alarm uses the maximum across collected filesystems for the instance.

## Code rollback

A replacement container that never becomes healthy triggers an attempt to start the prior image automatically. Failure is still reported, so the release marker is not updated. If ALB verification fails after local health succeeds, the job fails and requires operator diagnosis; the controller does not automatically roll back networking.

For a manual rollback, use an approved SSM operator process to run the **reviewed** `scripts/deploy-host.sh` with the environment, region, known prior ECR image digest and correct EBS volume ID. Verify local health, ALB health, login and migrations, then update `/autoapp/ENV/deployed-digest` to the actual deployed digest. CI production role can only deploy via the current-dev promotion rule. Retain ECR images needed for rollback; no destructive lifecycle expiration is configured.

The `pre-release.db` file on the data volume is made with SQLite's online backup API while writes are stopped. It is overwritten at each release. It is an immediate recovery aid, not an independent disaster recovery backup. Code rollback does **not** restore the database: an incompatible migration requires a planned maintenance restore and explicit data-loss assessment.

## Backup restore drill

Daily AWS Backup snapshots provide crash-consistent EBS recovery, including the SQLite WAL files. Nominal snapshot RPO is up to 24 hours, subject to successful backup jobs; recovery time is unmeasured until tested. Configure backup-job failure monitoring centrally before production acceptance.

1. Verify a completed recovery point in the environment's vault; record timestamp and volume ID.
2. Restore to a **new** encrypted EBS volume in an isolated recovery instance's AZ using an authorized restore role. The bootstrap role has backup permissions; restore permissions are an operator responsibility.
3. Mount the restored volume on an isolated instance with no production traffic. Ensure database, WAL and SHM files are restored together.
4. Run SQLite `PRAGMA integrity_check`; start the pinned known-good app image against the restored data. Test login, MFA, scope records and expected audit entries. Do not run production remediations.
5. Record elapsed recovery time and missing transactions; agree RTO/RPO based on this evidence.
6. Cut over only through an approved maintenance procedure; update Terraform ownership/import and attachment references to the restored volume. Never attach the same writable SQLite volume to two running applications.

For application-consistent recovery points beyond crash consistency, schedule SQLite online backups to independently encrypted off-host storage and test them. Daily EBS snapshots alone are not a guarantee that recovery meets your business requirements.

## Host patching and replacement

Use a reviewed SSM patch baseline or maintenance runbook, test in dev, then patch/reboot production in a window. Updating `ami_id` or changing subnet/instance replacement fields is blocked by `prevent_destroy`. Plan an explicit restore/replacement procedure; never simply remove protection to force an apply. User-data changes are not automatically rerun on an existing EC2 instance; apply equivalent changes through reviewed SSM maintenance or replace the instance deliberately.

## Cleanup and costs

NAT and ALB continue charging when EC2 is stopped. List all resources before cleanup. Back up/restore-test required data, review the destroy plan and disable deletion/termination protections only with an approved maintenance change. Terraform `prevent_destroy` must be intentionally removed for instance/data destruction. Delete retained recovery points and ECR images only after retention approval. Keep state and audit evidence under your organization's retention policy. No automatic destroy workflow is provided.

## Validation record

See `VALIDATION.md` for the checks actually performed when this implementation was prepared. A passing unit test or parsed Terraform file is not evidence that the AWS deployment works. Run the complete acceptance checklist in the README in your account.
