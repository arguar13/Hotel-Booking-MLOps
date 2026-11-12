# The EKS cluster and node group get their IAM roles from the
# terraform-aws-modules/eks/aws module (eks.tf). This file declares:
#
#   1. The S3 policy the API, MLflow and the batch jobs need on the artifacts
#      bucket, attached to the node group's role (eks.tf,
#      iam_role_additional_policies) instead of one IRSA role per
#      ServiceAccount. Coarser - every pod on the node inherits it - but for one
#      node group and one bucket it avoids an OIDC provider and a role per
#      service. With several teams on the cluster, IRSA becomes worth it.
#   2. The role GitLab CI assumes through OIDC to push images, read/write the
#      DVC bucket and deploy with kubectl.

data "aws_iam_policy_document" "artifacts_bucket_rw" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.mlflow_dvc_artifacts.arn,
      "${aws_s3_bucket.mlflow_dvc_artifacts.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "artifacts_bucket_rw" {
  name   = "${var.project_name}-artifacts-bucket-rw"
  policy = data.aws_iam_policy_document.artifacts_bucket_rw.json
}

# OIDC federation for GitLab CI/CD: .gitlab-ci.yml assumes an AWS role with no
# static access key stored in GitLab. GitLab issues the token through
# `id_tokens:` (see .gitlab-ci.yml); the provider is read here (usually already
# registered in the account) and the trust policy limits who may assume the role.
variable "gitlab_oidc_issuer_url" {
  description = "GitLab OIDC issuer URL (https://gitlab.com for SaaS, or your self-managed instance URL)"
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = "GitLab project path, e.g. \"my-group/hotel-mlops\"; restricts which pipeline can assume the CI role"
  type        = string
  default     = "CHANGE_ME/hotel-mlops"
}

# An IAM OIDC provider is a singleton per issuer URL for the whole AWS account,
# not per Terraform state. Reading it as data adopts the existing one instead of
# creating, or later destroying, an account-wide resource other projects may use.
data "aws_iam_openid_connect_provider" "gitlab" {
  url = var.gitlab_oidc_issuer_url
}

resource "aws_iam_role" "gitlab_ci_role" {
  name = "${var.project_name}-gitlab-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.gitlab.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.gitlab_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
          # Only the branches that .gitlab-ci.yml lets reach AWS (main/master):
          # with ref:* any branch or merge request of the project could assume a
          # role that can push images and deploy to the cluster.
          StringLike = {
            "${replace(var.gitlab_oidc_issuer_url, "https://", "")}:sub" = [
              "project_path:${var.gitlab_project_path}:ref_type:branch:ref:main",
              "project_path:${var.gitlab_project_path}:ref_type:branch:ref:master",
            ]
          }
        }
      }
    ]
  })
}

# CI needs to (1) push images to ECR, (2) read/write the artifacts bucket
# (DVC push/pull, the dataset) and (3) run `kubectl apply -k` in the deploy job.
resource "aws_iam_role_policy_attachment" "gitlab_ci_ecr_push" {
  role       = aws_iam_role.gitlab_ci_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "gitlab_ci_s3_dvc" {
  role       = aws_iam_role.gitlab_ci_role.name
  policy_arn = aws_iam_policy.artifacts_bucket_rw.arn
}

# kubectl access for the CI role through an EKS access entry. AmazonEKSAdminPolicy
# is broad on purpose for this scope; a shared cluster would scope it to the
# hotel-mlops namespace with a narrower access policy.
resource "aws_eks_access_entry" "gitlab_ci" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gitlab_ci_role.arn
}

resource "aws_eks_access_policy_association" "gitlab_ci_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gitlab_ci_role.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

output "gitlab_ci_role_arn" {
  value       = aws_iam_role.gitlab_ci_role.arn
  description = "ARN to set as AWS_ROLE_ARN in .gitlab-ci.yml"
}
