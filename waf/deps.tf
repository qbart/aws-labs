resource "random_pet" "id" {}

locals {
  name = "${random_pet.id.id}-test"
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

# group attached to EC2 instances
resource "aws_security_group" "default" {
  name   = local.name
  vpc_id = module.vpc.vpc_id
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

resource "aws_key_pair" "deployer" {
  key_name   = local.name
  public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
}

module "ecs_cluster" {
  source  = "Selleo/backend/aws//modules/ecs-cluster"
  version = "0.4.0"

  name_prefix        = local.name
  region             = "eu-central-1"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnets
  instance_type      = "t3.small"
  security_groups    = [aws_security_group.default.id]
  loadbalancer_sg_id = module.lb.loadbalancer_sg_id
  key_name           = aws_key_pair.deployer.key_name

  autoscaling_group = {
    min_size         = 1
    max_size         = 2
    desired_capacity = 1
  }
}

module "ecs_service" {
  source  = "Selleo/backend/aws//modules/ecs-service"
  version = "0.4.0"

  name           = "rails-api"
  vpc_id         = module.vpc.vpc_id
  ecs_cluster_id = module.ecs_cluster.ecs_cluster_id
  desired_count  = 1
  instance_role  = module.ecs_cluster.instance_role

  container_definition = {
    cpu_units      = 256
    mem_units      = 512
    command        = ["bundle", "exec", "ruby", "main.rb"],
    image          = "qbart/hello-ruby-sinatra:latest",
    container_port = 4567
    envs = {
      "APP_ENV" = "production"
    }
  }
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = module.lb.loadbalancer_id
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = module.ecs_service.lb_target_group_id
    type             = "forward"
  }
}

