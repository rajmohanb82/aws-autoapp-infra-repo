terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source = "hashicorp/aws", version = "= 6.20.0"
    }
  }
}
provider "aws" {
  region = var.region
}
variable "region" {
  default = "ap-south-1"
}
variable "state_bucket" {
  type = string
}
variable "existing_oidc_provider_arn" {
  default = ""
}
data "aws_caller_identity" "current" {}
locals {
  account = data.aws_caller_identity.current.account_id
}
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
  lifecycle {
    prevent_destroy = true
  }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_policy" "tls" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"], Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_ecr_repository" "app" {
  name                 = "autoapp"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  lifecycle {
    prevent_destroy = true
  }
}
resource "aws_iam_role" "backup" {
  name = "autoapp-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Service = "backup.amazonaws.com"
      }, Action = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
resource "aws_iam_role" "ci" {
  for_each = toset(["infra-dev", "infra-production", "app-dev", "app-production"])
  name     = "autoapp-${each.key}-ci"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Federated = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
        }, Action = "sts:AssumeRoleWithWebIdentity", Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub" = startswith(each.key, "infra-") ? [
            "repo:rajmohanb82/aws-autoapp-infra-repo:environment:${split("-", each.key)[1]}",
            "repo:rajmohanb82/aws-autoapp-infra-repo:environment:${split("-", each.key)[1]}-infra-apply"
          ] : ["repo:rajmohanb82/AWS-automation-app-repo:environment:${split("-", each.key)[1]}"]

        }
      }
    }]
  })
}
resource "aws_iam_role_policy" "infra" {
  for_each = toset(["dev", "production"])
  role     = aws_iam_role.ci["infra-${each.key}"].id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        Effect = "Allow", Action = ["ec2:*", "elasticloadbalancing:*", "logs:*", "cloudwatch:*", "sns:*", "backup:*"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["iam:CreateRole", "iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies", "iam:ListInstanceProfilesForRole", "iam:ListAttachedRolePolicies", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole"], Resource = "arn:aws:iam::${local.account}:role/autoapp-${each.key}-instance"
      },
      {
        Effect = "Allow", Action = ["iam:CreateInstanceProfile", "iam:GetInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile"], Resource = "arn:aws:iam::${local.account}:instance-profile/autoapp-${each.key}"
      },
      {
        Effect = "Allow", Action = ["iam:PassRole"], Resource = aws_iam_role.backup.arn, Condition = {
          StringEquals = {
            "iam:PassedToService" = "backup.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.state.arn
      },
      {
        Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.state.arn}/${each.key}/terraform.tfstate"
      },
      {
        Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.state.arn}/${each.key}/terraform.tfstate.tflock"
      }
    ]
  })
}
resource "aws_iam_role_policy" "app" {
  for_each = toset(["dev", "production"])
  role     = aws_iam_role.ci["app-${each.key}"].id
  policy = jsonencode({
    Version = "2012-10-17", Statement = concat([
      {
        Effect = "Allow", Action = ["ecr:GetAuthorizationToken", "ec2:DescribeInstances", "ec2:DescribeVolumes", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "elasticloadbalancing:DescribeTargetHealth"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages"], Resource = aws_ecr_repository.app.arn
      },
      {
        Effect = "Allow", Action = ["ssm:SendCommand"], Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
      },
      {
        Effect = "Allow", Action = ["ssm:SendCommand"], Resource = "arn:aws:ec2:${var.region}:${local.account}:instance/*", Condition = {
          StringEquals = {
            "ssm:resourceTag/Environment" = each.key, "ssm:resourceTag/Project" = "autoapp"
          }
        }
      },
      {
        Effect = "Allow", Action = ["ssm:GetParameter"], Resource = "arn:aws:ssm:${var.region}:${local.account}:parameter/autoapp/dev/deployed-digest"
      },
      {
        Effect = "Allow", Action = ["ssm:GetParameter", "ssm:PutParameter"], Resource = "arn:aws:ssm:${var.region}:${local.account}:parameter/autoapp/${each.key}/deployed-digest"
      }
      ], each.key != "dev" ? [] : [{
        Effect = "Allow", Action = ["ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"], Resource = aws_ecr_repository.app.arn
    }])
  })
}
output "ci_role_arns" {
  value = {
    for k, v in aws_iam_role.ci : k => v.arn
  }
}
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}
output "backup_role_arn" {
  value = aws_iam_role.backup.arn
}
