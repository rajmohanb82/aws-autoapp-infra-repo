data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_caller_identity" "current" {}
locals {
  name = "autoapp-${var.environment}"
  prod = var.environment == "production"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}
resource "aws_vpc" "main" {
  cidr_block           = local.prod ? "10.42.0.0/16" : "10.41.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = local.name
  }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = local.azs[count.index]
}
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 10)
  availability_zone = local.azs[0]
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
  domain = "vpc"
}
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  egress {
    from_port   = 5080
    to_port     = 5080
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private.cidr_block]
  }
}
resource "aws_security_group" "app" {
  name   = "${local.name}-app"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 5080
    to_port         = 5080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "main" {
  name                       = local.name
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
  enable_deletion_protection = local.prod
}
resource "aws_lb_target_group" "app" {
  name                 = local.name
  port                 = 5080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30
  health_check {
    path                = "/healthz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
resource "aws_iam_role" "instance" {
  name = "${local.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Service = "ec2.amazonaws.com"
      }, Action = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "runtime" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = concat([
      {
        Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/autoapp"
      },
      {
        Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      }
      , { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "AutoApp" } } }
      ], length(var.runtime_assume_role_arns) == 0 ? [] : [{
        Effect = "Allow", Action = ["sts:AssumeRole"], Resource = var.runtime_assume_role_arns
    }])
  })
}
resource "aws_iam_instance_profile" "main" {
  name = local.name
  role = aws_iam_role.instance.name
}
resource "aws_cloudwatch_log_group" "app" {
  name              = "/autoapp/${var.environment}"
  retention_in_days = local.prod ? 90 : 14
}
resource "aws_instance" "app" {
  ami                         = var.ami_id
  instance_type               = local.prod ? "t3.medium" : "t3.small"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.main.name
  associate_public_ip_address = false
  monitoring                  = local.prod
  disable_api_termination     = local.prod
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }
  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = false
  tags = {
    Name = local.name
  }
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [aws_route_table_association.private, aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.runtime]
}
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.private.availability_zone
  size              = local.prod ? 50 : 10
  type              = "gp3"
  encrypted         = true
  tags = {
    Name = "${local.name}-data", Backup = "true"
  }
  lifecycle {
    prevent_destroy = true
  }
}
resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.app.id
  stop_instance_before_detaching = true
}
resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 5080
}
resource "aws_sns_topic" "alerts" {
  name = local.name
}
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${local.name}-unhealthy"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}
resource "aws_cloudwatch_metric_alarm" "status" {
  alarm_name          = "${local.name}-instance-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions = {
    InstanceId = aws_instance.app.id
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}
resource "aws_backup_vault" "main" {
  name = local.name
}
resource "aws_backup_plan" "main" {
  name = local.name
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 20 * * ? *)"
    lifecycle {
      delete_after = local.prod ? 35 : 7
    }
  }
}
resource "aws_backup_selection" "data" {
  name         = local.name
  plan_id      = aws_backup_plan.main.id
  iam_role_arn = var.backup_role_arn
  resources    = [aws_ebs_volume.data.arn]
}
output "instance_id" {
  value = aws_instance.app.id
}
output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
output "alb_dns_name" {
  value = aws_lb.main.dns_name
}
output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}
output "runtime_role_arn" {
  value = aws_iam_role.instance.arn
}

resource "aws_cloudwatch_metric_alarm" "host" {
  for_each = {
    disk   = { metric = "disk_used_percent", threshold = 80 }
    memory = { metric = "mem_used_percent", threshold = 85 }
  }
  alarm_name          = "${local.name}-${each.key}"
  namespace           = "AutoApp"
  metric_name         = each.value.metric
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
