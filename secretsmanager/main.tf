resource "aws_secretsmanager_secret" "example" {
  name = "example"
}

data "aws_secretsmanager_secret" "example" {
  name = "example"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version#version_stages
data "aws_secretsmanager_secret_version" "example" {
  secret_id     = data.aws_secretsmanager_secret.example.id
  version_stage = "AWSCURRENT"
}

output "abc" {
  value     = jsondecode(data.aws_secretsmanager_secret_version.example.secret_string)["abc"]
  sensitive = true
}

output "def" {
  value     = jsondecode(data.aws_secretsmanager_secret_version.example.secret_string)["def"]
  sensitive = true
}
