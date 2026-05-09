variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Ubuntu AMI ID"
  type        = string
}

variable "allowed_ssh_ip" {
  description = "Allowed SSH CIDR"
  type        = string
  default     = "0.0.0.0/0"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "statuspulse"
}