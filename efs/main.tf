resource "aws_security_group_rule" "ec2_allow_outbound_to_efs" {
  security_group_id = aws_security_group.default.id
  type              = "egress"
  description       = "Allow to connect to EFS"
  from_port         = 2049
  protocol          = "tcp"
  to_port           = 2049
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

# SG attached to EFS
resource "aws_security_group" "efs" {
  name   = "${local.name}-efs"
  vpc_id = module.vpc.vpc_id
}

# Allow to connect from default SG
resource "aws_security_group_rule" "efs_allow_ec2" {
  security_group_id        = aws_security_group.efs.id
  type                     = "ingress"
  description              = "From EC2"
  from_port                = 2049
  protocol                 = "tcp"
  to_port                  = 2049
  source_security_group_id = aws_security_group.default.id
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
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "subnet2" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.public_subnets[1]
  security_groups = [aws_security_group.efs.id]
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

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
    ]

    resources = ["*"]
  }
}

output "efs" {
  value = aws_efs_file_system.this.arn
}
