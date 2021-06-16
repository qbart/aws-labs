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
        mountPoints       = [],
        volumesFrom       = [],
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

  #   service_registries {
  #     registry_arn =
  #   }
}

resource "aws_route53_zone" "this" {
  name = local.name

  vpc {
    vpc_id     = module.vpc.vpc_id
    vpc_region = var.region
  }
}
