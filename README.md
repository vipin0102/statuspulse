# StatusPulse Infrastructure

Terraform setup for provisioning StatusPulse infrastructure on AWS.

## Resources Created

- EC2 Instance
- Security Group
- Docker environment
- FastAPI app
- Caddy reverse proxy
- Uptime Kuma

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured
- Existing AWS key pair

## Usage

### Initialize Terraform

terraform init

### Review Plan

terraform plan

### Apply Infrastructure

terraform apply

### Destroy Infrastructure

terraform destroy

## Outputs

After deployment Terraform outputs:

- Public IP
- Public DNS

## Access

Main App:
https://<server-ip>

Uptime Kuma:
https://<server-ip>:8443