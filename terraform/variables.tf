variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base name for the project's resources"
  type        = string
  default     = "hotel-mlops"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "VPC CIDR range"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDR ranges allowed to reach the public EKS API endpoint. Open by
    default because both the operator (kubectl from a dynamic home IP) and
    the CI runner (the `deploy` job runs `kubectl apply -k` directly) need
    the cluster. For a real environment, restrict it to known egress IPs
    (office/VPN, CI runner), or set cluster_endpoint_public_access = false
    in eks.tf and go through a bastion.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_username" {
  description = "RDS PostgreSQL admin user"
  type        = string
  default     = "mlops_user"
}
