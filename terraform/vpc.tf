module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # Dedicated subnets for RDS, with no route to the internet
  database_subnets             = ["10.0.201.0/24", "10.0.202.0/24"]
  create_database_subnet_group = true

  # One NAT gateway instead of one per AZ: cheaper, at the cost of losing
  # private-subnet egress if that AZ goes down.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.project_name}-eks-nodes-sg"
  description = "Security group for the EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Besides the cluster security group the EKS module attaches, the control plane
# must reach each kubelet (10250) for `kubectl logs/exec`, and nodes must reach
# each other for pod-to-pod traffic across instances. Without these rules
# `kubectl get pods` still works (the kubelet reports outwards) but logs/exec
# fail with "TLS handshake timeout", which looks like an app problem and is not.
# AWS minimum rules for node security groups:
# https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html
resource "aws_security_group_rule" "eks_nodes_from_cluster_kubelet" {
  description              = "Kubelet API (logs/exec/metrics) from the EKS control plane"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = module.eks.cluster_security_group_id
}

resource "aws_security_group_rule" "eks_nodes_from_cluster_webhooks" {
  description              = "Ephemeral ports for webhooks and extension API servers (e.g. metrics-server) from the control plane"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = module.eks.cluster_security_group_id
}

resource "aws_security_group_rule" "eks_nodes_self" {
  description       = "Pod-to-pod traffic between nodes (VPC CNI)"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes_sg.id
  self              = true
}

# PostgreSQL reachable only from the EKS nodes
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "PostgreSQL from the EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from the EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes_sg.id]
  }
}
