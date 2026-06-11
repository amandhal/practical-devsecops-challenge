# Practical DevSecOps Challenge README

## Overview

This repository provisions a small Docker Swarm lab on AWS using Terraform and demonstrates secure multi-host container communication across nodes. The environment consists of one **bastion** host in a public subnet, one **swarm manager** in a private subnet, and one **swarm worker** in a different private subnet, with private egress provided through a NAT gateway.

The design focuses on four goals:

- Provision infrastructure with Infrastructure as Code (Terraform).
- Secure Docker remote access with TLS so the Docker client on the bastion can manage the swarm manager safely.
- Demonstrate encrypted overlay networking across nodes.
- Use Docker Swarm service discovery so containers can reach services by DNS name.

## Architecture

### Nodes

- **Bastion host**: Publicly reachable administration jump host. It has only the Docker CLI installed and is used to run swarm and service commands remotely.
- **Node A - Swarm Manager**: Private EC2 instance running Docker Engine and acting as the swarm manager.
- **Node B - Swarm Worker**: Private EC2 instance running Docker Engine and joining the swarm as a worker.

### Network layout

- Bastion is placed in a public subnet.
- Manager and worker are placed in separate private subnets.
- Private nodes use a NAT gateway for outbound internet access.
- Security groups and subnet isolation restrict access to only required ports between trusted hosts.

## Security model

This setup uses Docker Engine over TLS so the bastion can talk to the manager securely.

## Prerequisites

Before running the deployment, ensure the following are available:

- AWS credentials with permissions to create VPC, subnets, route tables, NAT gateway, EC2 instances, IAM/SSM resources, and security groups.
- Terraform installed locally.
- An SSH key pair for bastion access.
- A clone of this repository.

## Deployment steps

### 1. Clone the repository

```bash
git clone https://github.com/amandhal/practical-devsecops-challenge.git
cd practical-devsecops-challenge
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Apply the infrastructure

```bash
terraform apply -auto-approve
```

After apply completes, the EC2 instances and networking should be created. The manager user_data installs Docker Engine and prepares TLS assets; the worker user_data installs Docker Engine; the bastion user_data installs the Docker CLI.

## Access the machines

Use AWS SSM to access the swarm manager and swarm worker. Use SSH to access the bastion.

## Copy required TLS certificates and keys to bastion from swarm-manager node

The bastion needs the Docker client certificates generated on the swarm manager so it can manage the remote Docker daemon securely over TLS.

Copy these files from the manager:

- `/etc/docker/certs/ca.pem`
- `/etc/docker/certs/cert.pem`
- `/etc/docker/keys/key.pem`

Place them on the bastion under `~/.docker/`:

After copying:

```bash
chmod 644 ~/.docker/ca.pem ~/.docker/cert.pem
chmod 600 ~/.docker/key.pem
```

Add the manager hostname mapping on the bastion host:

```bash
sudo vim /etc/hosts
```

Add an entry like:

```text
<swarm-manager-private-ip> swarm-manager
```

Verify remote connectivity:

```bash
docker ps
```

## Initialize the swarm

Run the following on the manager node:

```bash
docker swarm init --advertise-addr <swarm-manager-private-ip>
```

The command prints a join token for workers. Copy the full worker join command.

## Join the worker node

Log in to the worker node and run the join command printed by the manager, for example:

Back on the manager or from the bastion via remote Docker, verify the cluster:

```bash
docker node ls
```

## Create the encrypted overlay network

From the bastion, create an encrypted attachable overlay network:

```bash
docker network create \
  --opt encrypted \
  --driver overlay \
  --attachable \
  practical-devsecops-challenge
```

## Deploy example services

### Deploy nginx on Node A (manager)

```bash
docker service create \
  --name nginx \
  --network practical-devsecops-challenge \
  --constraint 'node.hostname==<manager-hostname>' \
  nginx
```

### Deploy httpd on Node B (worker)

```bash
docker service create \
  --name httpd \
  --network practical-devsecops-challenge \
  --constraint 'node.hostname==<worker-hostname>' \
  httpd
```

Check service placement:

```bash
docker service ls
docker service ps nginx
docker service ps httpd
```

<img width="1514" height="362" alt="image" src="https://github.com/user-attachments/assets/5ef6d4e1-9d57-43eb-a975-1aff6d5368b7" />


## Demonstrate service discovery and cross-node communication

Docker Swarm provides service discovery through an embedded DNS system, and services on the same swarm network can resolve each other by service name.

Launch a temporary container on the same overlay network:

```bash
docker run --rm -it \
  --network practical-devsecops-challenge \
  nicolaka/netshoot bash
```

Inside the container, test DNS-based access:

```bash
curl nginx
curl httpd
```
<img width="1136" height="244" alt="image" src="https://github.com/user-attachments/assets/aaad6846-6e45-453c-866e-b8b817511ee8" />

<img width="742" height="590" alt="image" src="https://github.com/user-attachments/assets/c475604b-bf72-4d9c-8973-9fdcdd01903f" />


Expected result:

- `curl nginx` reaches the nginx service on the manager node.
- `curl httpd` reaches the httpd service on the worker node.
- Name resolution works without hardcoding container IP addresses because Swarm service discovery resolves service names on the overlay network.

You can also inspect the network and services:

```bash
docker network inspect practical-devsecops-challenge
docker service inspect nginx
docker service inspect httpd
```


## Cleanup

Destroy the lab when finished using:
```bash
terraform destroy -auto-approve
```

```bash
terraform destroy -auto-approve
```

This removes the AWS infrastructure and helps reduce cost and exposure.
