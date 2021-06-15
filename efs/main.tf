resource "random_pet" "id" {}

locals {
  name = "${random_pet.id.id}-test"
}

resource "aws_key_pair" "deployer" {
  key_name   = local.name
  public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.name
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "testing"
  }
}

resource "aws_security_group" "default" {
  name   = local.name
  vpc_id = module.vpc.vpc_id
}

module "lb" {
  source  = "Selleo/backend/aws//modules/load-balancer"
  version = "0.2.5"

  name       = local.name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets
}

module "ecs_cluster" {
  source  = "Selleo/backend/aws//modules/ecs-cluster"
  version = "0.2.5"

  name_prefix        = local.name
  key_name           = aws_key_pair.deployer.key_name
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnets
  instance_type      = "t3.small"
  security_groups    = [aws_security_group.default.id]
  loadbalancer_sg_id = module.lb.loadbalancer_sg_id

  autoscaling_group = {
    min_size         = 1
    max_size         = 2
    desired_capacity = 1
  }
}

resource "aws_security_group_rule" "allow_ssh" {
  security_group_id = aws_security_group.default.id
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_security_group_rule" "efs_outbound" {
  security_group_id = aws_security_group.default.id
  type              = "egress"
  description       = "Allow All Outbound"
  from_port         = 0
  protocol          = "-1"
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}


resource "aws_security_group_rule" "with_efs_in" {
  security_group_id = aws_security_group.default.id
  type              = "ingress"
  description       = "In efs"
  from_port         = 2049
  protocol          = "tcp"
  to_port           = 2049
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_security_group_rule" "with_efs_out" {
  security_group_id = aws_security_group.default.id
  type              = "egress"
  description       = "out efs"
  from_port         = 2049
  protocol          = "tcp"
  to_port           = 2049
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_efs_file_system" "this" {
  creation_token   = local.name
  throughput_mode  = "bursting"
  performance_mode = "generalPurpose"

  tags = {
    "Name" = local.name
  }
}

resource "aws_efs_mount_target" "subnet1" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.public_subnets[0]
  security_groups = [aws_security_group.efs.id, aws_security_group.default.id]
}

resource "aws_efs_mount_target" "subnet2" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.public_subnets[1]
  security_groups = [aws_security_group.efs.id, aws_security_group.default.id]
}

resource "aws_security_group" "efs" {
  name   = "${local.name}-efs"
  vpc_id = module.vpc.vpc_id
}

# resource "aws_security_group_rule" "efs_inbound" {
#   security_group_id = aws_security_group.efs.id
#   type              = "ingress"
#   description       = "NFS Inbound"
#   from_port         = 2999
#   to_port           = 2999
#   protocol          = "tcp"
#   self              = true
# }

resource "aws_security_group_rule" "efs_nfs" {
  security_group_id = aws_security_group.efs.id
  type              = "ingress"
  description       = "NFS"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_security_group_rule" "efs_nfs_out" {
  security_group_id = aws_security_group.efs.id
  type              = "egress"
  description       = "NFS"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_security_group_rule" "with_efs_ecs" {
  security_group_id        = aws_security_group.efs.id
  type                     = "ingress"
  description              = "from ecs"
  from_port                = 2049
  protocol                 = "tcp"
  to_port                  = 2049
  source_security_group_id = aws_security_group.default.id
}


resource "aws_security_group_rule" "efs_out" {
  security_group_id = aws_security_group.efs.id
  type              = "egress"
  description       = "Allow All Outbound"
  from_port         = 0
  protocol          = "-1"
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_ecs_task_definition" "this" {
  family = local.name

  container_definitions = jsonencode(
    [
      {
        essential         = true,
        memoryReservation = 256,
        cpu               = 256,
        name              = local.name
        image             = "qbart/go-http-server-noop:latest",
        mountPoints = [
          {
            sourceVolume  = "service-storage"
            containerPath = "/mnt/efs"
            readOnly      = false
          }
        ],
        volumesFrom = [],
        portMappings = [
          {
            containerPort = 5000,
            hostPort      = 0,
            protocol      = "tcp",
          },
        ],
        environment = [],
      }
  ])

  volume {
    name = "service-storage"

    efs_volume_configuration {
      file_system_id = aws_efs_file_system.this.id
      # root_directory = "/"
      # transit_encryption      = "ENABLED"
      # transit_encryption_port = 2999
    }
  }
}

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = module.ecs_cluster.ecs_cluster_id
  task_definition = aws_ecs_task_definition.this.id
  iam_role        = aws_iam_role.ecs.arn

  load_balancer {
    target_group_arn = aws_alb_target_group.this.arn
    container_name   = local.name
    container_port   = 5000
  }

  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
}

resource "aws_iam_role" "ecs" {
  name               = "${local.name}-ecs"
  assume_role_policy = data.aws_iam_policy_document.ecs.json
}

data "aws_iam_policy_document" "ecs" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "alb" {
  name   = "${local.name}-role-alb-policy"
  role   = aws_iam_role.ecs.name
  policy = data.aws_iam_policy_document.alb.json
}

data "aws_iam_policy_document" "alb" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:RegisterTargets"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "efs" {
  name   = "${local.name}-efs"
  role   = module.ecs_cluster.instance_role
  policy = data.aws_iam_policy_document.efs.json
}

data "aws_iam_policy_document" "efs" {
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:DescribeTags",
    ]

    resources = [
      aws_efs_file_system.this.arn
    ]
  }
}

resource "aws_alb_target_group" "this" {
  name                 = local.name
  port                 = 5000
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30 # draining time

  health_check {
    path                = "/"
    protocol            = "HTTP"
    timeout             = 10
    interval            = 15
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

output "lb" {
  value = module.lb.loadbalancer_dns_name
}

output "efs" {
  value = aws_efs_file_system.this.arn
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = module.lb.loadbalancer_id
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.this.arn
    type             = "forward"
  }
}

# resource "aws_efs_file_system_policy" "policy" {
#   file_system_id = aws_efs_file_system.this.id

#   policy = <<POLICY
# {
#     "Version": "2012-10-17",
#     "Id": "ExamplePolicy01",
#     "Statement": [
#         {
#             "Sid": "ExampleStatement01",
#             "Effect": "Allow",
#             "Principal": {
#                 "AWS": "*"
#             },
#             "Resource": "${aws_efs_file_system.this.arn}",
#             "Action": [
#                 "elasticfilesystem:ClientMount",
#                 "elasticfilesystem:ClientWrite"
#             ]
#         }
#     ]
# }
# POLICY
# }
