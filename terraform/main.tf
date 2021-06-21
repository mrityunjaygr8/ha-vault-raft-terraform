terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.45.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "2.21.0"
    }
  }
}

variable "az" {
  default = ["a", "b", "c"]
}

variable "access_key" {
  type = string
}

variable "secret_key" {
  type = string
}

variable "site_domain" {
  type    = string
  default = "imparham.in"
}

provider "aws" {
  # Configuration options
  region     = "us-east-1"
  access_key = var.access_key
  secret_key = var.secret_key
}

provider "cloudflare" {}


resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    "Name" = "MAIN-VPC"
  }
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    "Name" = "MAIN-IGW"
  }
}

resource "aws_subnet" "main_subnet" {
  vpc_id            = aws_vpc.main.id
  count             = length(var.az)
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "us-east-1${var.az[count.index]}"
  tags = {
    "Name" = "PUBLIC-SUBNET-us-east-1${var.az[count.index]}"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  count             = length(var.az)
  cidr_block        = "10.0.1${count.index}.0/24"
  availability_zone = "us-east-1${var.az[count.index]}"
  tags = {
    "Name" = "PRIVATE-SUBNET-us-east-1${var.az[count.index]}"
  }
}

resource "aws_route" "main_r" {
  route_table_id         = aws_vpc.main.default_route_table_id
  gateway_id             = aws_internet_gateway.main_igw.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "main_rta" {
  route_table_id = aws_vpc.main.default_route_table_id
  subnet_id      = aws_subnet.main_subnet[count.index].id
  count          = length(var.az)
}

resource "aws_security_group" "main_sg" {
  vpc_id      = aws_vpc.main.id
  description = "The SG for our stuff"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_pet" "env" {
  length    = 2
  separator = "_"
}

resource "aws_kms_key" "vault" {
  description             = "Vault unseal key"
  deletion_window_in_days = 10

  tags = {
    Name = "vault-kms-unseal-${random_pet.env.id}"
  }
}

resource "aws_instance" "main_instance" {
  # subnet_id              = aws_subnet.private[count.index].id
  subnet_id              = aws_subnet.main_subnet[count.index].id
  ami                    = "ami-0484fe720524acc8a"
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.main_sg.id]
  count                  = length(var.az)
  key_name               = "msyt-key-pair"
  user_data = templatefile("${path.module}/userdata.sh", {
    AWS_REGION           = "us-east-1"
    kms_key              = aws_kms_key.vault.id
    AWS_SECRET_KEY       = var.secret_key,
    AWS_ACCESS_KEY       = var.access_key
    count                = count.index
    VAULT_S3_BUCKET_NAME = aws_s3_bucket.vault_data.id
  })
  availability_zone = "us-east-1${var.az[count.index]}"

  tags = {
    "Name"  = "vault-server",
    "vault" = "server",
  }
}

resource "aws_eip" "eip" {
  count    = length(var.az)
  instance = aws_instance.main_instance[count.index].id
}

output "ip_1" {
  value = aws_eip.eip[0].public_ip
}
output "ip_2" {
  value = aws_eip.eip[1].public_ip
}
output "ip_3" {
  value = aws_eip.eip[2].public_ip
}

resource "aws_elb" "elb" {
  name    = "MERA-ELB"
  subnets = [for i, v in var.az : aws_subnet.main_subnet[i].id]
  listener {
    instance_port      = 8200
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "arn:aws:acm:us-east-1:261508060912:certificate/05c07772-9c8a-499d-8749-7bbe524349fc"
  }



  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 3
    target              = "HTTP:8200/v1/sys/health?standbyok=true"
    interval            = 30
  }
  security_groups = [aws_security_group.main_sg.id]
  instances       = [for i, v in var.az : aws_instance.main_instance[i].id]
  # cross_zone_load_balancing   = true
  # idle_timeout                = 400
  # connection_draining         = true
  # connection_draining_timeout = 400

  tags = {
    "Name" = "MAIN-ELB"
  }
}

output "dns" {
  value = aws_elb.elb.dns_name
}

data "cloudflare_zones" "domain" {
  filter {
    name = var.site_domain
  }
}

resource "cloudflare_record" "site_cname" {
  zone_id = data.cloudflare_zones.domain.zones[0].id
  name    = "vault"
  value   = aws_elb.elb.dns_name
  type    = "CNAME"

  ttl     = 1
  proxied = false
}

variable "main_project_tag" {
  default = "MAIN"
}

## S3 Bucket for Vault Data
resource "aws_s3_bucket" "vault_data" {
  bucket_prefix = "main-bucket"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = merge({ "Project" = var.main_project_tag }, { "Name" = "MAIN-BUCKET" })
}

## S3 Bucket Public Access Block
resource "aws_s3_bucket_public_access_block" "vault_data" {
  bucket                  = aws_s3_bucket.vault_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
