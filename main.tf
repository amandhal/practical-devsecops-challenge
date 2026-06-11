module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "practical-devsecops-challenge"
  cidr = var.vpc_cidr_block

  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
}

module "docker_swarm_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/docker-swarm"
  version = "6.0.0"

  name        = "docker-swarm"
  description = "Security group for docker-swarm-nodes"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_ipv4 = {
    vpc = module.vpc.vpc_cidr_block
  }

  ingress_rules = {
    docker-over-tls = {
      description = "Docker over TLS"
      from_port   = 2376
      to_port     = 2376
      ip_protocol = "tcp"
      cidr_ipv4   = var.vpc_cidr_block
    }

    overlay-encryption = {
      description = "IPSec ESP for overlay network with encryption"
      ip_protocol = "50"
      cidr_ipv4   = var.vpc_cidr_block
    }
  }
}

module "ec2_instance_swarm_manager" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.0"

  name          = "swarm-manager"
  ami           = "ami-07a00cf47dbbc844c"
  instance_type = var.instance_type
  user_data     = file("${path.module}/user-data-scripts/swarm-manager.sh")

  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [module.docker_swarm_security_group.id]

  create_iam_instance_profile = true
  iam_role_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

module "ec2_instance_swarm_worker" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.0"

  name          = "swarm-worker"
  ami           = "ami-07a00cf47dbbc844c"
  instance_type = var.instance_type
  user_data     = file("${path.module}/user-data-scripts/swarm-worker.sh")

  subnet_id              = module.vpc.private_subnets[1]
  vpc_security_group_ids = [module.docker_swarm_security_group.id]

  create_iam_instance_profile = true
  iam_role_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

module "ec2_instance_bastion_host" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.0"

  name          = "bastion_host"
  key_name      = "bastion-host-key-pair"
  ami           = "ami-07a00cf47dbbc844c"
  instance_type = var.instance_type
  user_data     = file("${path.module}/user-data-scripts/bastion-host.sh")

  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true

  create_security_group = true
  security_group_vpc_id = module.vpc.vpc_id
  security_group_ingress_rules = {
    ssh = {
      from_port   = 22
      to_port     = 22
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}
