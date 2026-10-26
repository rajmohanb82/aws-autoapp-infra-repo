# Setup — execute in this order

## 1. Prerequisites and decisions

Use Terraform 1.14.0, AWS CLI v2, Git, Python 3.12 and Docker on your workstation. GitHub-hosted Ubuntu runners provide Docker for CI. Choose `ap-south-1` unless changing every environment setting consistently. You need an AWS account, a domain with DNS control, a validated ACM certificate **in the same region as the ALB**, a corporate/VPN egress CIDR and an alert email.

The authoring environment has no connected AWS session. No AWS resources have been created. Placeholder values must be replaced by your real values. Set a budget before the first apply; destroying the stack is deliberately protected.

## 2. Prepare protected GitHub branches and environments

Review and merge the application PR into `dev`. The infra repo starts on `main`; after reviewing the implementation, create `dev` and `production` from the reviewed commit. Create application `production` from the reviewed `dev` commit. Thereafter promote changes through PRs. Require passing CI and reviews; disallow force pushes and direct production pushes.

In **both** repos create GitHub environments `dev` and `production`. Restrict each to its same-named branch. Require a reviewer and prevent self-review for production where your GitHub plan supports it. If reviewers are unavailable under your plan, do not assume the environment provides approval; use your organization's protected release process.

In the **infra** repo additionally create `dev-infra-apply` and `production-infra-apply`. Restrict to `dev` and `production` respectively. Require production reviewers here: this is the gate **after the plan is available**. Copy AWS_ROLE_ARN, AWS_REGION and STATE_BUCKET from the matching base environment into its apply environment. Reviewers inspect the plan job before approving apply.

Do not create broad wildcard OIDC subjects. Environment protection and branch protection are part of the trust boundary: an environment-bound OIDC token does not independently attest a branch name.

## 3. One-time bootstrap using your authorized AWS SSO profile

The bootstrap creates state storage, GitHub OIDC federation, a shared ECR repository, backup service role and four CI roles. Do not use long-lived access keys.

```bash
aws configure sso --profile autoapp-admin
aws sso login --profile autoapp-admin
export AWS_PROFILE=autoapp-admin
aws sts get-caller-identity
cd aws-autoapp-infra-repo
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan \
  -var='state_bucket=YOUR-GLOBALLY-UNIQUE-STATE-BUCKET' \
  -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
terraform -chdir=bootstrap output
```

If the account already has `token.actions.githubusercontent.com`, include `-var='existing_oidc_provider_arn=arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com'` in the plan. Only one provider for that URL can exist per account.

The infrastructure CI role provisions networking and IAM, so its service-level permissions are intentionally broad for this dedicated project account. It is not a fully least-privilege enterprise Terraform role. Do not install it in a shared production account unchanged. The app CI role is limited to its environment's tagged EC2 instances, the shared ECR image path and the deployment marker parameters. Production app CI cannot push images.

### Persist bootstrap state securely

After bootstrap, migrate its local state to the newly created bucket. This state is separate from environment state and is managed by the admin SSO identity.

```bash
cat > bootstrap/backend.tf <<'EOF'
terraform {
  backend "s3" {}
}
EOF
terraform -chdir=bootstrap init -migrate-state \
  -backend-config='bucket=YOUR-GLOBALLY-UNIQUE-STATE-BUCKET' \
  -backend-config='key=bootstrap/terraform.tfstate' \
  -backend-config='region=ap-south-1' \
  -backend-config='encrypt=true' \
  -backend-config='use_lockfile=true'
```

Confirm the migration and secure/remove any residual local state backups according to your policy. Commit `bootstrap/backend.tf`; never commit state or a plan. Do not give app CI access to state. S3 versioning helps recover accidental state changes; it is not an application database backup.

## 4. Set infra environment variables

In each infra `dev` and `production` environment set these **GitHub environment variables**, not AWS keys:

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | Bootstrap output for `infra-dev` or `infra-production` |
| `AWS_REGION` | `ap-south-1` |
| `STATE_BUCKET` | Bootstrap bucket name |
| `AMI_ID` | Tested x86_64 AL2023 AMI in this region |
| `CERTIFICATE_ARN` | Validated ACM certificate ARN |
| `ALLOWED_CIDRS` | JSON array, e.g. `["YOUR.PUBLIC.IP/32"]` |
| `ALERT_EMAIL` | Monitored email address |
| `BACKUP_ROLE_ARN` | Bootstrap backup role ARN |

Find a current candidate AMI through SSM, test it, then pin its ID. Automatically changing AMIs is intentionally avoided because this single-host design cannot do a zero-downtime replacement.

```bash
aws ssm get-parameter --region ap-south-1 \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text
```

Copy the three apply-stage variables described in step 2 into `dev-infra-apply` and `production-infra-apply`.

## 5. Provision dev, then production

GitHub → infrastructure repo → Actions → Terraform → Run workflow. Select the `dev` branch and `environment=dev`. Initially leave `apply=false`; inspect the plan. Run again with `apply=true` when ready; this creates a new plan, then applies that exact saved plan after the apply job's environment gate. Repeat using branch/environment `production` and review its plan before approving.

The workflow initializes native S3 state locking and uses distinct state keys. PRs run fmt and validate without AWS credentials. Apply does not run automatically on an unreviewed PR. Plans remain as short-lived Actions artifacts and may contain sensitive infrastructure metadata; restrict repository/Actions access.

Record outputs: `instance_id`, `data_volume_id`, `target_group_arn`, `alb_dns_name`, `runtime_role_arn`. Wait for EC2 bootstrap/cloud-init to complete and the instance to appear Online in Systems Manager before app deployment. Confirm the SNS email subscription.

## 6. Set application environment variables

In the app repo, set these in `dev` and `production`:

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | Bootstrap output for `app-dev` or `app-production` |
| `AWS_REGION` | Same region as infrastructure |
| `ECR_REPOSITORY` | Bootstrap ECR URL: `ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com/autoapp` |
| `INSTANCE_ID` | Matching infrastructure output |
| `DATA_VOLUME_ID` | Matching data EBS volume output |
| `TARGET_GROUP_ARN` | Matching ALB target group output |

Review these IDs carefully; do not copy dev IDs to production. The deployment controller verifies environment/project instance tags and volume attachment before executing the script.

## 7. Deploy and initialize dev

Push a reviewed change to app `dev`. CI runs tests, dependency audit, Docker build, Trivy HIGH/CRITICAL gate and a runtime health check. Delivery rebuilds/scans the release image, pushes a unique immutable tag and resolves its digest. SSM mounts the exact EBS volume, stops the old container, backs up SQLite, starts the replacement and checks container/ALB health. On local health failure it attempts a code rollback and fails the workflow.

Create a DNS alias/CNAME for the ALB matching your ACM certificate, e.g. `dev-ops.example.com`. Open `https://dev-ops.example.com` from an allowed IP. The default ALB DNS name will not match your custom certificate. Complete the first-run administrator setup and MFA while the CIDR allowlist is restricted to the operator. The live database starts empty; the database previously committed in the repo is excluded from the release.

Runtime AWS authentication uses the EC2 instance role via the default boto3 credential chain; no `~/.aws` bind mount is used. The base instance role has no inventory/remediation permissions. For scans, add explicit cross-account audit role ARNs through `runtime_assume_role_arns`, apply Terraform and configure those target account role names in the portal. Target roles must trust the runtime role. Start read-only and test denied remediation; grant write operations only through a separately reviewed policy.

## 8. Promote to production

1. Merge the reviewed application commit/config into branch `production` through a PR. Production pushes run no release automatically.
2. Retrieve the successful dev image digest from the delivery logs or `/autoapp/dev/deployed-digest` SSM parameter.
3. Actions → Application CI and delivery → Run workflow → branch `production` → enter that digest.
4. CI reruns. The production environment reviewer checks the dev deployment and release change before approving delivery.
5. The workflow verifies the digest equals the current successful dev marker, pulls/scans it, and deploys it without rebuilding. An older dev digest is deliberately rejected by this simple promotion model.
6. Verify production ALB health, HTTPS login and logs. Complete production's own empty-database setup/MFA.

Rollback to an older production image is an operator procedure in OPERATIONS.md, not this current-dev promotion workflow.

## 9. Local checks

```bash
python3.12 -m venv .venv
. .venv/bin/activate
pip install -r portal/requirements.txt pytest==8.3.5 pip-audit
python -m pytest -q
pip-audit -r portal/requirements.txt
docker build -t autoapp:local portal
# Run without DEPLOY_ENV for plain HTTP local testing; cloud deployments require HTTPS cookies.
docker run --rm -p 127.0.0.1:5080:5080 --tmpfs /app/data:uid=1000,gid=1000 autoapp:local
```

In the infrastructure checkout: `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, then repeat init/validate with `-chdir=bootstrap`. Never disable provider checksum verification to make a failed init pass.
