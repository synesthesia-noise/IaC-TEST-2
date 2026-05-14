# main.tf — minimal nginx demo for the platform's BYOC apply flow.
#
# This is user-authored Terraform source. The user (the demonstrator) pushes
# this file to a registered git repository (e.g.,
# https://github.com/synesthesia-noise/IaC-TEST); the platform fetches and
# applies it on the user's behalf inside the user's member AWS account
# (which the platform created at POST /services time).
#
# What this declares — to be brought into existence inside the user's
# member account by the platform's terraform_runner:
#   - One EC2 t3.micro instance running Amazon Linux 2023, in the default
#     VPC's default public subnet, with a dynamic public IP.
#   - One security group allowing TCP/80 from anywhere.
#   - Amazon Linux 2023's dnf installs Docker; user_data runs an
#     nginx:1.27 container on port 80.
#
# Total resources: 2 (security group + instance).
#
# Demo URL retrieval (Path A): the user assumes `customer-readonly-role`
# cross-account into their own member account, then queries AWS directly.
# See README.md in this folder for the assume-role + describe-instances
# recipe.

terraform {
  required_version = ">= 1.10"

  # ─────────────────────────────────────────────────────────────────────────
  # FILL IN before pushing: replace the two REPLACE-* tokens with the per-app
  # state bucket name returned by the platform after POST /services completes
  # (when `provisioning_status` transitions to "active" on the services row).
  # The bucket-name format is:
  #     platform-tfstate-<app-name>-dev-<member-account-id>
  # Both values appear in the `GET /services/{app}` response.
  #
  # `use_lockfile = true` enables Terraform 1.10+'s native S3 object-based
  # locking — no separate DynamoDB lock table needed. The state bucket has
  # versioning enabled by the platform's USER/REGISTRATION bootstrap, which
  # is the requirement for native locking.
  # ─────────────────────────────────────────────────────────────────────────
  backend "s3" {
    bucket       = "platform-tfstate-nginx-test-1-dev-719484290126"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Default VPC: already has an IGW attached and default subnets routing
# 0.0.0.0/0 to it. No networking-layer resources need to be declared.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 x86_64 AMI; portable across regions.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "nginx" {
  name        = "nginx-demo-sg"
  description = "Allow HTTP from anywhere for the nginx demo."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress (for dnf package install + docker image pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nginx-demo-sg"
  }
}

resource "aws_instance" "nginx" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.nginx.id]
  associate_public_ip_address = true

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y docker
    systemctl enable --now docker
    docker run -d --restart=always -p 80:80 nginx:1.27
  EOT

  tags = {
    Name = "nginx-demo"
  }
}

# Output emits the public-IP-based URL Terraform sees at apply time. The
# platform does NOT currently return this via API (see post-MVP backlog
# § "Platform-API environment-state inspection"); the user retrieves it
# authoritatively via Path A — assume customer-readonly-role, then
# `aws ec2 describe-instances --filters Name=tag:Name,Values=nginx-demo`.
output "url" {
  description = "Public URL of the nginx demo (dynamic IP)."
  value       = "http://${aws_instance.nginx.public_ip}"
}
