resource "aws_ecs_task_definition" "this" {
  family = local.name

  requires_compatibilities = ["EXTERNAL"]
  network_mode             = "awsvpc"

  container_definitions = jsonencode(
    [
      {
        essential   = true,
        memory      = 256,
        cpu         = 256,
        name        = local.name
        image       = "qbart/go-http-server-noop:latest",
        mountPoints = [],
        volumesFrom = [],
        portMappings = [
          {
            containerPort = 5000,
            hostPort      = 5000, # ports must match
            protocol      = "tcp",
          },
        ],
        environment = [],
      }
  ])

  proxy_configuration {
    type           = "APPMESH"
    container_name = "applicationContainerName"
    properties = {
      AppPorts         = "5000"
      EgressIgnoredIPs = "169.254.170.2,169.254.169.254"
      IgnoredUID       = "1337"
      ProxyEgressPort  = 15001
      ProxyIngressPort = 15000
    }
  }
}

resource "aws_ecs_service" "this" {
  name    = local.name
  cluster = module.ecs_cluster.ecs_cluster_id
  # task_definition = aws_ecs_task_definition.this.id
  # iam_role = aws_iam_role.ecs.arn

  # load_balancer {
  #   target_group_arn = aws_alb_target_group.this.arn
  #   container_name   = local.name
  #   container_port   = 5000
  # }
  #

  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  deployment_controller { type = "EXTERNAL" }

  # service_registries {
  #   registry_arn = aws_service_discovery_service.this.arn
  # }
}

resource "aws_appmesh_mesh" "this" {
  name = local.name

  spec {
    egress_filter {
      type = "DROP_ALL"
    }
  }
}

resource "aws_appmesh_virtual_node" "this" {
  name      = local.name
  mesh_name = aws_appmesh_mesh.this.id

  spec {
    backend {
      virtual_service {
        virtual_service_name = "go.app.local"
      }
    }

    listener {
      port_mapping {
        port     = 5000
        protocol = "http"
      }

      health_check {
        protocol            = "http"
        path                = "/"
        healthy_threshold   = 2
        unhealthy_threshold = 2
        timeout_millis      = 2000
        interval_millis     = 5000
      }
    }

    service_discovery {
      aws_cloud_map {
        attributes = {
          ECS_TASK_SET_EXTERNAL_ID = "go-task-set"
        }

        service_name   = "go"
        namespace_name = aws_service_discovery_private_dns_namespace.this.name
      }
    }

    logging {
      access_log {
        file {
          path = "/dev/stdout"
        }
      }
    }
  }
}

resource "aws_appmesh_virtual_router" "this" {
  name      = local.name
  mesh_name = aws_appmesh_mesh.this.id

  spec {
    listener {
      port_mapping {
        port     = 5000
        protocol = "http"
      }
    }
  }
}

resource "aws_appmesh_route" "this" {
  name                = local.name
  mesh_name           = aws_appmesh_mesh.this.id
  virtual_router_name = aws_appmesh_virtual_router.this.name

  spec {
    http_route {
      match {
        prefix = "/"
      }

      action {
        weighted_target {
          virtual_node = aws_appmesh_virtual_node.this.name
          weight       = 100
        }
      }
    }
  }
}

resource "aws_appmesh_virtual_service" "this" {
  name      = "go.${local.name}"
  mesh_name = aws_appmesh_mesh.this.id

  spec {
    provider {
      virtual_node {
        virtual_node_name = aws_appmesh_virtual_node.this.name
      }
    }
  }
}

# resource "aws_route53_zone" "this" {
#   name = local.name

#   # specifing VPC makes it private
#   vpc {
#     vpc_id     = module.vpc.vpc_id
#     vpc_region = var.region
#   }
# }
#

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.name
  description = local.name
  vpc         = module.vpc.vpc_id
}

output "hosted_zone" {
  value = aws_service_discovery_private_dns_namespace.this.hosted_zone
}

resource "aws_service_discovery_service" "this" {
  name = local.name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    dns_records {
      ttl  = 10
      type = "SRV"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}


