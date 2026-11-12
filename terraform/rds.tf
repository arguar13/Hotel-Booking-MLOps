# Generated here and copied by hand into a plain Kubernetes Secret (see
# kubernetes/base/mlops-config.env and the README, "Deploying"). Less automatic
# than syncing it from AWS, but it needs no extra infrastructure at this size;
# with several operators and credential rotation, automating it pays off.
# The value ends up in the Terraform state, so the state bucket must stay
# private.
resource "random_password" "db_password" {
  length  = 24
  special = false # safe to paste into a shell or a connection string
}

resource "aws_db_instance" "mlflow_db" {
  identifier        = "${var.project_name}-db"
  engine            = "postgres"
  engine_version    = "18.3"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "postgres"
  username          = var.db_username
  password          = random_password.db_password.result

  # Single instance, no Multi-AZ or read replicas: at this scale the extra
  # availability does not justify the cost or the failover operations.
  multi_az = false

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true
  publicly_accessible = false

  # Encryption at rest with the AWS-managed aws/rds key. It cannot be turned on
  # for an existing instance: changing it forces a replacement.
  storage_encrypted = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

output "rds_endpoint" {
  value       = aws_db_instance.mlflow_db.endpoint
  description = "RDS endpoint for MLflow (goes into kubernetes/overlays/production/mlops-config.env)"
}

output "db_password" {
  value       = random_password.db_password.result
  description = "Generated RDS password, for the Kubernetes Secret (README, Deploying): `terraform output -raw db_password`"
  sensitive   = true
}
