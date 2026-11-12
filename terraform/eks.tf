module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project_name}-cluster"
  cluster_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Since v20 of the module the IAM principal that creates the cluster gets no
  # Kubernetes permissions by default (access entries replaced the aws-auth
  # ConfigMap): without this, kubectl fails with "Unauthorized" for everyone.
  # It creates the creator's access entry with AmazonEKSClusterAdminPolicy.
  enable_cluster_creator_admin_permissions = true

  # No IRSA: the single node group below carries the S3 policy the API and
  # MLflow need (iam_role_additional_policies). Coarser, since every pod on the
  # node inherits it, but with one node group and one bucket it avoids an OIDC
  # provider and one role per service (see iam.tf).
  enable_irsa = false

  eks_managed_node_groups = {
    # One node group: at this volume there is no need for separate serving and
    # batch pools.
    general = {
      desired_size = 2
      min_size     = 1
      max_size     = 3

      instance_types         = ["t3.medium"]
      vpc_security_group_ids = [aws_security_group.eks_nodes_sg.id]

      # Read/write on the artifacts bucket for every pod (api, mlflow, jobs); see iam.tf.
      iam_role_additional_policies = {
        s3_artifacts = aws_iam_policy.artifacts_bucket_rw.arn
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}
