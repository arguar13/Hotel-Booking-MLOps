resource "aws_s3_bucket" "mlflow_dvc_artifacts" {
  bucket = "${var.project_name}-artifacts-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Trained models and DVC-versioned data must never be public. All four flags are
# set so that a public ACL or policy added by mistake has no effect.
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.mlflow_dvc_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 (AES-256, AWS-managed keys). A customer-managed KMS key would add a
# per-request cost and a key policy to maintain, for nothing this project needs
# (no regulated data, no on-demand rotation requirement).
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.mlflow_dvc_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning: an overwritten model or DVC object can always be recovered.
resource "aws_s3_bucket_versioning" "artifacts_versioning" {
  bucket = aws_s3_bucket.mlflow_dvc_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Objects older than 90 days move to Standard-IA: old runs are rarely read.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts_lifecycle" {
  bucket = aws_s3_bucket.mlflow_dvc_artifacts.id

  rule {
    id     = "archive-old-artifacts"
    status = "Enabled"

    # Empty filter = "every object in the bucket". Required explicitly:
    # a rule with neither `filter` nor `prefix` is a provider warning today
    # and an error in a future AWS provider version.
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

output "s3_bucket_name" {
  value = aws_s3_bucket.mlflow_dvc_artifacts.id
}
