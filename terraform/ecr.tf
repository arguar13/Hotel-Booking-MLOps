locals {
  ecr_repositories = {
    api       = "${var.project_name}-api"
    dashboard = "${var.project_name}-dashboard"
    # Batch workloads: core_ml's code packaged to run inside the cluster
    # (Dockerfile.jobs) - the drift-check CronJob and manual training/promotion
    # runs all use it, with a different `command:`.
    jobs = "${var.project_name}-jobs"
    # MLflow itself is NOT built here: kubernetes/base/mlflow.yaml runs the
    # official ghcr.io/mlflow/mlflow image directly, so there is no image for
    # this project's own CI to build or push for it.
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories
  name     = each.value
  # Mutable so ":latest" can be re-pushed. IMMUTABLE would rule out overwriting
  # a tag that is already deployed; CI deploys by commit SHA either way.
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # ECR's free basic scan on every push. Not a substitute for a dedicated
  # scanner, but it adds no tool to the pipeline.
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep the last 30 images per repository to bound storage cost.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "ecr_repository_urls" {
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
  description = "ECR repository URLs (api, dashboard, jobs)"
}
