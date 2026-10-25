#!/bin/bash
set -euo pipefail
dnf install -y docker amazon-ssm-agent xfsprogs util-linux amazon-cloudwatch-agent
systemctl enable --now docker amazon-ssm-agent
install -d -m 0750 /opt/autoapp
# Application CI mounts the separately attached EBS volume by its volume ID.
# Never initialise a disk using a guessed /dev/nvme name.

cat > /opt/aws/amazon-cloudwatch-agent/etc/autoapp.json <<'CONFIG'
{
  "agent": {"metrics_collection_interval": 60},
  "metrics": {
    "namespace": "AutoApp",
    "append_dimensions": {"InstanceId": "${aws:InstanceId}"},
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem": {"measurement": ["mem_used_percent"]},
      "disk": {"measurement": ["used_percent"], "resources": ["/", "/opt/autoapp/data"], "ignore_file_system_types": ["sysfs", "devtmpfs", "tmpfs"]}
    }
  }
}
CONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/autoapp.json -s
