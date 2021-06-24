resource "random_pet" "id" {}

locals {
  name = "${random_pet.id.id}-test"
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

module "lb" {
  source  = "Selleo/backend/aws//modules/load-balancer"
  version = "0.3.0"
  #   source = "/home/bart/selleo/terraform-aws-backend/modules/load-balancer"

  name       = local.name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets
}

module "ecs_cluster" {
  # source  = "Selleo/backend/aws//modules/ecs-cluster"
  # version = "0.3.0"

  source = "/home/bart/selleo/terraform-aws-backend/modules/ecs-cluster"

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

  #cloudinit_parts = [
  #  {
  #    filename     = "test.cfg"
  #    content_type = "text/cloud-config"
  #    content      = <<SH
  ##!/usr/bin/env bash

  #echo "Configure ECS cluster 2"
  #SH
  #  }
  #]
}

